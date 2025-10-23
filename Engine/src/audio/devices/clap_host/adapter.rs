//! CLAP plugin adapter that implements the AudioDevice trait

use std::collections::HashMap;
use std::path::Path;
use clack_host::prelude::*;
use clack_host::events::event_types::*;
use clack_host::events::UnknownEvent;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use super::super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamValue, ParamInfo};
use super::host_impl::{SonaraHost, SonaraHostShared, SonaraHostMainThread, SonaraHostAudioProcessor};
use super::PluginError;

/// Wraps a CLAP plugin instance to implement our AudioDevice trait
pub struct ClapDeviceAdapter {
    // Plugin metadata
    device_id: String,
    device_name: String,
    device_vendor: String,
    device_version: String,
    category: DeviceCategory,
    
    // Bundle and instance (lifetime: bundle outlives instance)
    _bundle: PluginBundle,
    instance: Option<PluginInstance<SonaraHost>>,
    audio_processor: Option<PluginAudioProcessorEnum<SonaraHost>>,
    
    // Parameter mapping (CLAP param ID -> our sequential ParamId)
    param_map: HashMap<ClapId, ParamId>,
    reverse_param_map: HashMap<ParamId, ClapId>,
    param_info_cache: Vec<ParamInfo>,
    
    // Audio buffer management (pre-allocated for real-time safety)
    input_buffers: Vec<Vec<f32>>,
    output_buffers: Vec<Vec<f32>>,
    input_ports: AudioPorts,
    output_ports: AudioPorts,
    
    // Event buffers (MIDI -> CLAP events)
    // Store note-on/off events separately since UnknownEvent is a DST
    note_on_events: Vec<NoteOnEvent>,
    note_off_events: Vec<NoteOffEvent>,
    output_event_buffer: EventBuffer,
    
    // State
    sample_rate: f32,
    max_buffer_size: usize,
    
    // Lifecycle and bypass state
    is_active: bool,
    is_enabled: bool,
}

impl ClapDeviceAdapter {
    /// Create a new CLAP device adapter
    pub fn new(
        bundle_path: &Path,
        plugin_id: &str,
        sample_rate: f32,
        max_buffer_size: usize,
    ) -> Result<Self, PluginError> {
        tracing::info!(
            "Loading CLAP plugin {} from {:?} (SR: {}, buffer: {})",
            plugin_id, bundle_path, sample_rate, max_buffer_size
        );

        // 1. Load bundle
        let bundle = unsafe {
            PluginBundle::load(bundle_path)
                .map_err(|e| PluginError::LoadError(format!("Failed to load bundle: {:?}", e)))?
        };
        
        // 2. Find plugin descriptor
        let factory = bundle.get_plugin_factory()
            .ok_or_else(|| PluginError::UnsupportedPlugin("No plugin factory".to_string()))?;
        
        let descriptor = factory.plugin_descriptors()
            .find(|d| {
                d.id()
                    .and_then(|id| id.to_str().ok())
                    .map(|id| id == plugin_id)
                    .unwrap_or(false)
            })
            .ok_or_else(|| PluginError::NotFound(format!("Plugin {} not found in bundle", plugin_id)))?;
        
        // Extract metadata
        let device_id = descriptor.id()
            .and_then(|id| id.to_str().ok())
            .unwrap_or("unknown")
            .to_string();
        
        let device_name = descriptor.name()
            .and_then(|n| n.to_str().ok())
            .unwrap_or("Unknown Plugin")
            .to_string();
        
        let device_vendor = descriptor.vendor()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("Unknown")
            .to_string();
        
        let device_version = descriptor.version()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("0.0.0")
            .to_string();
        
        let category = Self::infer_category(&descriptor);
        
        // 3. Create plugin instance
        let host_info = HostInfo::new(
            "Sonara",
            "Sonara Project",
            "https://github.com/sonara",
            "0.1.0"
        ).map_err(|e| PluginError::InitializationFailed(format!("Failed to create host info: {:?}", e)))?;
        
        let plugin_id_cstr = descriptor.id()
            .ok_or_else(|| PluginError::InvalidPluginId("Missing plugin ID".to_string()))?;
        
        let instance = PluginInstance::<SonaraHost>::new(
            |_| SonaraHostShared,
            |_| SonaraHostMainThread,
            &bundle,
            plugin_id_cstr,
            &host_info
        ).map_err(|e| PluginError::InitializationFailed(format!("Failed to create plugin instance: {:?}", e)))?;
        
        // 4. Query parameters (if plugin supports params extension)
        let param_info_cache = Vec::new(); // TODO: Query params via extension
        let param_map = HashMap::new();
        let reverse_param_map = HashMap::new();
        
        // 5. Pre-allocate buffers (2 channels stereo for now)
        let input_buffers = vec![vec![0.0f32; max_buffer_size]; 2];
        let output_buffers = vec![vec![0.0f32; max_buffer_size]; 2];
        let input_ports = AudioPorts::with_capacity(2, 1);
        let output_ports = AudioPorts::with_capacity(2, 1);
        
        tracing::info!("Successfully loaded plugin: {}", device_name);
        
        Ok(Self {
            device_id,
            device_name,
            device_vendor,
            device_version,
            category,
            _bundle: bundle,
            instance: Some(instance),
            audio_processor: None,
            param_map,
            reverse_param_map,
            param_info_cache,
            input_buffers,
            output_buffers,
            input_ports,
            output_ports,
            note_on_events: Vec::with_capacity(128),
            note_off_events: Vec::with_capacity(128),
            output_event_buffer: EventBuffer::new(),
            sample_rate,
            max_buffer_size,
            is_active: false,  // Plugin created but not activated
            is_enabled: true,  // Default to enabled (not bypassed)
        })
    }
    
    /// Activate the plugin for audio processing (internal implementation)
    fn activate_internal(&mut self) -> Result<(), PluginError> {
        if self.audio_processor.is_some() {
            tracing::warn!("Plugin already activated");
            return Ok(());
        }
        
        let mut instance = self.instance.take()
            .ok_or_else(|| PluginError::ActivationFailed("No plugin instance".to_string()))?;
        
        let audio_config = PluginAudioConfiguration {
            sample_rate: self.sample_rate as f64,
            min_frames_count: 64,
            max_frames_count: self.max_buffer_size as u32,
        };
        
        let audio_processor = instance.activate(
            |_, _| SonaraHostAudioProcessor,
            audio_config
        ).map_err(|e| PluginError::ActivationFailed(format!("Activation failed: {:?}", e)))?;
        
        // Store the processor (need to start processing and then wrap it)
        let started = audio_processor.start_processing()
            .map_err(|e| PluginError::ActivationFailed(format!("Failed to start processing: {:?}", e)))?;
        self.audio_processor = Some(PluginAudioProcessorEnum::Started(started));
        
        tracing::info!("Plugin activated: {}", self.device_name);
        Ok(())
    }
    
    /// Infer device category from CLAP plugin features
    fn infer_category(descriptor: &clack_host::factory::PluginDescriptor) -> DeviceCategory {
        for feature in descriptor.features() {
            if let Ok(feature_str) = feature.to_str() {
                match feature_str {
                    "instrument" | "synthesizer" | "sampler" => {
                        return DeviceCategory::Instrument;
                    }
                    "audio-effect" | "effect" => {
                        return DeviceCategory::Effect;
                    }
                    "analyzer" | "utility" => {
                        return DeviceCategory::Utility;
                    }
                    _ => {}
                }
            }
        }
        DeviceCategory::Effect
    }
}

impl AudioDevice for ClapDeviceAdapter {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Validate sample_count against buffer size
        if sample_count > self.max_buffer_size {
            tracing::error!(
                "sample_count ({}) exceeds max_buffer_size ({}) - clamping to avoid buffer overflow",
                sample_count, self.max_buffer_size
            );
            // Process only what we can safely handle
            let safe_sample_count = self.max_buffer_size;
            self.process_block(inputs, outputs, safe_sample_count);
            return;
        }
        
        // Handle bypass (device disabled)
        if !self.is_enabled {
            // Pass audio through unprocessed
            let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }
        
        // Handle inactive state
        if !self.is_active {
            // Output silence (plugin not activated)
            let output_len = (sample_count * 2).min(outputs.len());
            outputs[..output_len].fill(0.0);
            return;
        }
        
        // Ensure plugin is activated
        let Some(processor) = &mut self.audio_processor else {
            // This shouldn't happen if is_active is true, but handle it anyway
            tracing::warn!("Plugin marked active but no audio processor - outputting silence");
            let output_len = (sample_count * 2).min(outputs.len());
            outputs[..output_len].fill(0.0);
            return;
        };
        
        // 1. Copy interleaved input to plugin's deinterleaved buffers
        for i in 0..sample_count {
            let left_idx = i * 2;
            let right_idx = i * 2 + 1;
            if left_idx < inputs.len() && right_idx < inputs.len() {
                self.input_buffers[0][i] = inputs[left_idx];
                self.input_buffers[1][i] = inputs[right_idx];
            }
        }
        
        // 2. Prepare CLAP audio structures
        let input_audio = self.input_ports.with_input_buffers([AudioPortBuffer {
            latency: 0,
            channels: AudioPortBufferType::f32_input_only(
                self.input_buffers.iter_mut()
                    .map(|b| InputChannel::constant(&mut b[..sample_count]))
            )
        }]);
        
        let mut output_audio = self.output_ports.with_output_buffers([AudioPortBuffer {
            latency: 0,
            channels: AudioPortBufferType::f32_output_only(
                self.output_buffers.iter_mut()
                    .map(|b| &mut b[..sample_count])
            )
        }]);
        
        // 3. Prepare events (convert to references)
        let note_events_refs: Vec<&UnknownEvent> = self.note_on_events.iter()
            .map(|e| e.as_unknown())
            .chain(self.note_off_events.iter().map(|e| e.as_unknown()))
            .collect();
        let input_events = InputEvents::from_buffer(&note_events_refs);
        let mut output_events = OutputEvents::from_buffer(&mut self.output_event_buffer);
        
        // 4. Process audio (only if started)
        match processor {
            PluginAudioProcessorEnum::Started(started_processor) => {
                match started_processor.process(
                    &input_audio,
                    &mut output_audio,
                    &input_events,
                    &mut output_events,
                    None,
                    None
                ) {
                    Ok(_) => {
                        // 5. Copy plugin output to interleaved output buffer
                        for i in 0..sample_count {
                            let left_idx = i * 2;
                            let right_idx = i * 2 + 1;
                            if left_idx < outputs.len() && right_idx < outputs.len() {
                                outputs[left_idx] = self.output_buffers[0][i];
                                outputs[right_idx] = self.output_buffers[1][i];
                            }
                        }
                    }
                    Err(e) => {
                        tracing::error!("Plugin processing error: {:?}", e);
                        let output_len = (sample_count * 2).min(outputs.len());
                        outputs[..output_len].fill(0.0);
                    }
                }
            }
            _ => {
                // Plugin not started - output silence
                tracing::warn!("Plugin not started, outputting silence");
                let output_len = (sample_count * 2).min(outputs.len());
                outputs[..output_len].fill(0.0);
            }
        }
        
        // 6. Clear event buffers for next block
        self.note_on_events.clear();
        self.note_off_events.clear();
    }
    
    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool) {
        if is_note_on {
            // Create and store note-on event
            let event = NoteOnEvent::new(
                0,  // Sample offset (frame-accurate timing)
                Pckn::new(0u16, 0u16, note as u16, note as u32),  // Port, channel, key, note_id
                velocity as f64 / 127.0  // Normalize velocity
            );
            self.note_on_events.push(event);
        } else {
            // Create and store note-off event
            let event = NoteOffEvent::new(
                0,
                Pckn::new(0u16, 0u16, note as u16, note as u32),
                velocity as f64 / 127.0
            );
            self.note_off_events.push(event);
        }
    }
    
    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        // TODO: Map our ParamId to CLAP's ClapId and send ParamValueEvent
        tracing::debug!("Set parameter {} = {}", param_id, value);
    }
    
    fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
        // TODO: Query plugin's current parameter value
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
        // Clear event buffers and audio buffers
        self.note_on_events.clear();
        self.note_off_events.clear();
        self.input_buffers.iter_mut().for_each(|b| b.fill(0.0));
        self.output_buffers.iter_mut().for_each(|b| b.fill(0.0));
        tracing::debug!("Plugin reset: {}", self.device_name);
    }
    
    fn version(&self) -> &str {
        &self.device_version
    }
    
    // === Lifecycle Management ===
    
    fn is_active(&self) -> bool {
        self.is_active
    }
    
    fn activate(&mut self) -> Result<(), String> {
        if self.is_active {
            return Ok(()); // Already active
        }
        
        self.activate_internal()
            .map_err(|e| format!("Failed to activate plugin: {}", e))?;
        self.is_active = true;
        tracing::info!("Plugin {} activated", self.device_name);
        Ok(())
    }
    
    fn deactivate(&mut self) -> Result<(), String> {
        if !self.is_active {
            return Ok(()); // Already inactive
        }
        
        // Stop processing and deactivate
        if let Some(_processor) = self.audio_processor.take() {
            // Processor is dropped, which stops processing
            tracing::info!("Plugin {} deactivated (processor dropped)", self.device_name);
        }
        
        self.is_active = false;
        
        // Clear parameters when inactive
        self.param_info_cache.clear();
        
        Ok(())
    }
    
    // === Bypass Control ===
    
    fn is_enabled(&self) -> bool {
        self.is_enabled
    }
    
    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
        tracing::debug!("Plugin {} {} (bypass={})", 
            self.device_name, 
            if enabled { "enabled" } else { "disabled" },
            !enabled
        );
    }
}

// Implement Drop to ensure proper cleanup
impl Drop for ClapDeviceAdapter {
    fn drop(&mut self) {
        if self.audio_processor.is_some() {
            tracing::info!("Deactivating plugin: {}", self.device_name);
            // The audio processor will be dropped here
            // The instance was consumed during activation
            self.audio_processor = None;
        }
    }
}

// Safety: ClapDeviceAdapter can be sent between threads as long as we follow CLAP's threading model
// The audio processor is only used on the audio thread
unsafe impl Send for ClapDeviceAdapter {}

