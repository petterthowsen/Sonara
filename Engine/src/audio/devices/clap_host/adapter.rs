//! CLAP plugin adapter that implements the AudioDevice trait
// this is the in-process CLAP plugin adapter, currently not used.

use super::super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use super::host_impl::{
    SonaraHost, SonaraHostAudioProcessor, SonaraHostMainThread, SonaraHostShared,
};
use super::PluginError;
use clack_extensions::gui::{GuiApiType, GuiConfiguration, PluginGui};
use clack_host::events::event_types::*;
use clack_host::events::UnknownEvent;
use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_host::utils::Cookie;
use crossbeam::channel::{unbounded, Receiver, Sender};
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

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
    instance: PluginInstance<SonaraHost>, // Keep instance alive for GUI and parameter operations
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
    param_value_events: Vec<ParamValueEvent>,
    output_event_buffer: EventBuffer,

    // Current parameter values (for get_parameter)
    current_param_values: HashMap<ParamId, ParamValue>,

    // Parameter changes detected from plugin output events (for status updates)
    pending_param_changes: Vec<(ParamId, ParamValue)>,

    // State
    sample_rate: f32,
    max_buffer_size: usize,

    // Main thread callback flag
    pending_main_thread_callback: Arc<AtomicBool>,

    // GUI thread management
    gui_thread: Option<JoinHandle<()>>,
    gui_thread_shutdown: Arc<AtomicBool>,

    // Lifecycle and bypass state
    is_active: bool,
    is_enabled: bool,

    // GUI state (only used on main thread)
    gui_open: bool,
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
            plugin_id,
            bundle_path,
            sample_rate,
            max_buffer_size
        );

        // 1. Load bundle
        let bundle = unsafe {
            PluginBundle::load(bundle_path)
                .map_err(|e| PluginError::LoadError(format!("Failed to load bundle: {:?}", e)))?
        };

        // 2. Find plugin descriptor
        let factory = bundle
            .get_plugin_factory()
            .ok_or_else(|| PluginError::UnsupportedPlugin("No plugin factory".to_string()))?;

        let descriptor = factory
            .plugin_descriptors()
            .find(|d| {
                d.id()
                    .and_then(|id| id.to_str().ok())
                    .map(|id| id == plugin_id)
                    .unwrap_or(false)
            })
            .ok_or_else(|| {
                PluginError::NotFound(format!("Plugin {} not found in bundle", plugin_id))
            })?;

        // Extract metadata
        let device_id = descriptor
            .id()
            .and_then(|id| id.to_str().ok())
            .unwrap_or("unknown")
            .to_string();

        let device_name = descriptor
            .name()
            .and_then(|n| n.to_str().ok())
            .unwrap_or("Unknown Plugin")
            .to_string();

        let device_vendor = descriptor
            .vendor()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("Unknown")
            .to_string();

        let device_version = descriptor
            .version()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("0.0.0")
            .to_string();

        let category = Self::infer_category(&descriptor);

        // 3. Create plugin instance
        let host_info = HostInfo::new(
            "Sonara",
            "Sonara Project",
            "https://github.com/sonara",
            "0.1.0",
        )
        .map_err(|e| {
            PluginError::InitializationFailed(format!("Failed to create host info: {:?}", e))
        })?;

        let plugin_id_cstr = descriptor
            .id()
            .ok_or_else(|| PluginError::InvalidPluginId("Missing plugin ID".to_string()))?;

        let instance = PluginInstance::<SonaraHost>::new(
            |_| SonaraHostShared,
            |_| SonaraHostMainThread::new(),
            &bundle,
            plugin_id_cstr,
            &host_info,
        )
        .map_err(|e| {
            PluginError::InitializationFailed(format!("Failed to create plugin instance: {:?}", e))
        })?;

        // 4. Parameters will be queried after activation
        // (CLAP requires plugin to be fully initialized to query params)
        let param_info_cache = Vec::new();
        let param_map = HashMap::new();
        let reverse_param_map = HashMap::new();

        tracing::info!("Successfully loaded plugin: {}", device_name);

        // 5. Pre-allocate buffers (2 channels stereo for now)
        let input_buffers = vec![vec![0.0f32; max_buffer_size]; 2];
        let output_buffers = vec![vec![0.0f32; max_buffer_size]; 2];
        let input_ports = AudioPorts::with_capacity(2, 1);
        let output_ports = AudioPorts::with_capacity(2, 1);

        Ok(Self {
            device_id,
            device_name,
            device_vendor,
            device_version,
            category,
            _bundle: bundle,
            instance, // Keep instance for GUI operations
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
            param_value_events: Vec::with_capacity(32),
            output_event_buffer: EventBuffer::new(),
            current_param_values: HashMap::new(),
            pending_param_changes: Vec::new(),
            sample_rate,
            max_buffer_size,
            pending_main_thread_callback: Arc::new(AtomicBool::new(false)),
            gui_thread: None,
            gui_thread_shutdown: Arc::new(AtomicBool::new(false)),
            is_active: false, // Plugin created but not activated
            is_enabled: true, // Default to enabled (not bypassed)
            gui_open: false,  // GUI not open initially
        })
    }

    /// Activate the plugin for audio processing (internal implementation)
    fn activate_internal(&mut self) -> Result<(), PluginError> {
        if self.audio_processor.is_some() {
            tracing::warn!("Plugin already activated");
            return Ok(());
        }

        // Query parameters before activation (plugin must be initialized but not activated)
        tracing::info!("Querying plugin parameters...");
        let (param_infos, clap_to_our, our_to_clap) = Self::query_parameters(&mut self.instance);
        self.param_info_cache = param_infos;
        self.param_map = clap_to_our;
        self.reverse_param_map = our_to_clap;
        tracing::info!(
            "Loaded {} parameters from plugin",
            self.param_info_cache.len()
        );

        let audio_config = PluginAudioConfiguration {
            sample_rate: self.sample_rate as f64,
            min_frames_count: 64,
            max_frames_count: self.max_buffer_size as u32,
        };

        // Activate returns an audio processor but keeps the instance alive
        let audio_processor = self
            .instance
            .activate(|_, _| SonaraHostAudioProcessor, audio_config)
            .map_err(|e| PluginError::ActivationFailed(format!("Activation failed: {:?}", e)))?;

        // Store the processor (need to start processing and then wrap it)
        let started = audio_processor.start_processing().map_err(|e| {
            PluginError::ActivationFailed(format!("Failed to start processing: {:?}", e))
        })?;
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

    /// Query parameters from a CLAP plugin instance
    fn query_parameters(
        instance: &mut PluginInstance<SonaraHost>,
    ) -> (
        Vec<super::super::ParamInfo>,
        HashMap<ClapId, u32>,
        HashMap<u32, ClapId>,
    ) {
        use clack_extensions::params::PluginParams;

        // Get a main thread handle to query the plugin
        let mut handle = instance.plugin_handle();

        // Try to get the params extension
        let Some(params_ext): Option<PluginParams> = handle.get_extension() else {
            tracing::info!("Plugin does not support params extension");
            return (Vec::new(), HashMap::new(), HashMap::new());
        };

        // Query parameter count
        let param_count = params_ext.count(&mut handle);
        tracing::info!("Plugin has {} parameters", param_count);

        if param_count == 0 {
            return (Vec::new(), HashMap::new(), HashMap::new());
        }

        // Allocate output structures
        let mut param_infos = Vec::with_capacity(param_count as usize);
        let mut clap_to_our_id = HashMap::new();
        let mut our_to_clap_id = HashMap::new();

        // Query each parameter
        for i in 0..param_count {
            use clack_extensions::params::ParamInfoBuffer;

            let mut buffer = ParamInfoBuffer::new();

            if let Some(clap_info) = params_ext.get_info(&mut handle, i, &mut buffer) {
                // Extract parameter information
                let name = std::str::from_utf8(clap_info.name)
                    .unwrap_or("Unknown")
                    .trim_end_matches('\0')
                    .to_string();
                let module = std::str::from_utf8(clap_info.module)
                    .unwrap_or("")
                    .trim_end_matches('\0')
                    .to_string();

                let clap_id = clap_info.id;
                let our_id = i; // Use index as our sequential ID

                // Map IDs
                clap_to_our_id.insert(clap_id, our_id);
                our_to_clap_id.insert(our_id, clap_id);

                // Create our ParamInfo
                let param_info = super::super::ParamInfo {
                    id: our_id,
                    name,
                    unit: String::new(), // CLAP doesn't expose units in the same way
                    min: clap_info.min_value as f32,
                    max: clap_info.max_value as f32,
                    default: clap_info.default_value as f32,
                    is_automation_safe: clap_info
                        .flags
                        .contains(clack_extensions::params::ParamInfoFlags::IS_AUTOMATABLE),
                    param_type: super::super::ParamType::Float,
                    syncable: true,
                    enum_values: Vec::new(),
                    is_hidden: clap_info
                        .flags
                        .contains(clack_extensions::params::ParamInfoFlags::IS_HIDDEN),
                    is_read_only: clap_info
                        .flags
                        .contains(clack_extensions::params::ParamInfoFlags::IS_READONLY),
                    is_bypass: clap_info
                        .flags
                        .contains(clack_extensions::params::ParamInfoFlags::IS_BYPASS),
                    module,
                };

                tracing::debug!(
                    "  Param {}: {} (ID: {:?}, range: {:.2}-{:.2}, default: {:.2})",
                    i,
                    param_info.name,
                    clap_id,
                    param_info.min,
                    param_info.max,
                    param_info.default
                );

                param_infos.push(param_info);
            } else {
                tracing::warn!("Failed to query parameter info for index {}", i);
            }
        }

        (param_infos, clap_to_our_id, our_to_clap_id)
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

        // Handle inactive state (plugin not loaded - pass through to save RAM)
        if !self.is_active {
            // Pass audio through unprocessed (transparent when not loaded)
            let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }

        // Handle bypass (device disabled but still loaded)
        if !self.is_enabled {
            // Pass audio through unprocessed
            let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
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
                self.input_buffers
                    .iter_mut()
                    .map(|b| InputChannel::constant(&mut b[..sample_count])),
            ),
        }]);

        let mut output_audio = self.output_ports.with_output_buffers([AudioPortBuffer {
            latency: 0,
            channels: AudioPortBufferType::f32_output_only(
                self.output_buffers
                    .iter_mut()
                    .map(|b| &mut b[..sample_count]),
            ),
        }]);

        // 3. Prepare events (convert to references - include MIDI and parameter events)
        let note_events_refs: Vec<&UnknownEvent> = self
            .note_on_events
            .iter()
            .map(|e| e.as_unknown())
            .chain(self.note_off_events.iter().map(|e| e.as_unknown()))
            .chain(self.param_value_events.iter().map(|e| e.as_unknown()))
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
                    None,
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

        // 6. Process output events from the buffer (parameter changes from plugin)
        self.process_output_events();

        // 7. Clear event buffers for next block
        self.note_on_events.clear();
        self.note_off_events.clear();
        self.param_value_events.clear();
        self.output_event_buffer.clear();
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        if is_note_on {
            // Create and store note-on event
            let event = NoteOnEvent::new(
                frame_offset as u32, // Sample offset (frame-accurate timing)
                Pckn::new(0u16, 0u16, note as u16, note as u32), // Port, channel, key, note_id
                velocity as f64 / 127.0, // Normalize velocity
            );
            self.note_on_events.push(event);
        } else {
            // Create and store note-off event
            let event = NoteOffEvent::new(
                frame_offset as u32,
                Pckn::new(0u16, 0u16, note as u16, note as u32),
                velocity as f64 / 127.0,
            );
            self.note_off_events.push(event);
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        // Map our sequential ParamId to CLAP's ClapId
        let Some(&clap_id) = self.reverse_param_map.get(&param_id) else {
            tracing::warn!("Parameter ID {} not found in plugin", param_id);
            return;
        };

        // Get the parameter info to denormalize the value
        let param_info = self.param_info_cache.get(param_id as usize);
        let denormalized_value = if let Some(info) = param_info {
            // Denormalize from 0.0-1.0 to the parameter's actual range
            info.min as f64 + (value as f64 * (info.max - info.min) as f64)
        } else {
            value as f64 // Fallback: assume parameter is already in correct range
        };

        // Create parameter value event
        let event = ParamValueEvent::new(
            0, // Sample offset (immediate)
            clap_id,
            Pckn::new(0u16, 0u16, 0u16, 0u32), // Port, channel, key, note_id (not used for global params)
            denormalized_value,
            Cookie::empty(),
        );

        // Queue the event for the next process block
        self.param_value_events.push(event);

        // Update our local cache
        self.current_param_values.insert(param_id, value);

        tracing::debug!(
            "Set parameter {} = {} (CLAP ID: {:?}, denormalized: {:.2})",
            param_id,
            value,
            clap_id,
            denormalized_value
        );
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        // Return cached value
        self.current_param_values.get(&param_id).copied()
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
        self.param_value_events.clear();
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
        if let Some(processor) = self.audio_processor.take() {
            // Stop the processor and return it to deactivate properly
            let stopped = match processor {
                PluginAudioProcessorEnum::Started(started) => started.stop_processing(),
                _ => return Err("Plugin processor in invalid state".to_string()),
            };

            // Deactivate the plugin (returns control to main thread)
            self.instance.deactivate(stopped);
            tracing::info!("Plugin {} deactivated", self.device_name);
        }

        self.is_active = false;

        // Keep parameters available even when inactive
        // (User might want to see/edit them in the UI)

        Ok(())
    }

    // === Bypass Control ===

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
        tracing::debug!(
            "Plugin {} {} (bypass={})",
            self.device_name,
            if enabled { "enabled" } else { "disabled" },
            !enabled
        );
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

impl ClapDeviceAdapter {
    /// Open the plugin's GUI window (floating window mode)
    ///
    /// This must be called on the main thread, not the audio thread.
    /// Can be called while the plugin is activated for audio processing.
    pub fn open_gui(&mut self) -> Result<(), String> {
        if self.gui_open {
            return Ok(()); // Already open
        }

        // Get the plugin instance handle (instance is always available)
        let mut handle = self.instance.plugin_handle();

        // Try to get the GUI extension
        let Some(gui_ext): Option<PluginGui> = handle.get_extension() else {
            return Err("Plugin does not support GUI extension".to_string());
        };

        // Use the default API for the current platform (X11 on Linux)
        let Some(api_type) = GuiApiType::default_for_current_platform() else {
            return Err("No GUI API available for current platform".to_string());
        };

        let config = GuiConfiguration {
            api_type,
            is_floating: true, // We're using floating windows
        };

        // Check if the plugin supports this API
        if !gui_ext.is_api_supported(&mut handle, config) {
            return Err(format!("Plugin does not support {:?} GUI API", api_type));
        }

        // Create the GUI
        gui_ext
            .create(&mut handle, config)
            .map_err(|e| format!("Failed to create plugin GUI: {}", e))?;

        // For floating windows, we suggest a title (plugin will use it for its window)
        let title_cstr = std::ffi::CString::new(format!("{} - Sonara", self.device_name))
            .unwrap_or_else(|_| std::ffi::CString::new("Plugin - Sonara").unwrap());
        gui_ext.suggest_title(&mut handle, &title_cstr);

        // Show the window
        tracing::info!("Calling gui_ext.show()...");
        gui_ext
            .show(&mut handle)
            .map_err(|e| format!("Failed to show plugin GUI: {}", e))?;
        tracing::info!("gui_ext.show() returned successfully");

        // Process callbacks intensively for the first second to let the window appear
        // X11 windows need event processing to become visible
        tracing::info!("Processing initial callbacks to make window visible...");
        for i in 0..100 {
            self.instance.call_on_main_thread_callback();
            std::thread::sleep(Duration::from_millis(10));

            // Check if window appeared every 10 iterations
            if i % 10 == 0 {
                tracing::debug!("Callback batch {} complete", i / 10);
            }
        }
        tracing::info!("Initial callback processing complete");

        // TODO: Spawn a dedicated thread to keep processing callbacks
        // Challenge: PluginInstance is not Send, so it must stay on this thread
        // Solution for later: Create a separate process per plugin with IPC

        self.gui_open = true;
        tracing::info!("✅ Plugin GUI opened for: {}", self.device_name);
        tracing::warn!("⚠️  GUI may become unresponsive without continuous callback processing");
        tracing::warn!("⚠️  TODO: Implement dedicated GUI thread or process per plugin");
        Ok(())
    }

    /// Process output events from the plugin (parameter changes, etc.)
    fn process_output_events(&mut self) {
        use clack_host::events::event_types::ParamValueEvent;

        // Iterate through events in the output buffer
        for event in self.output_event_buffer.iter() {
            // Check if this is a parameter value event
            if let Some(param_event) = event.as_event::<ParamValueEvent>() {
                let Some(clap_id) = param_event.param_id() else {
                    continue; // Skip events without valid param ID
                };
                let value = param_event.value();

                // Map CLAP ID to our ParamId
                if let Some(&param_id) = self.param_map.get(&clap_id) {
                    // Get parameter info to normalize the value
                    if let Some(param_info) = self.param_info_cache.get(param_id as usize) {
                        // Normalize value from plugin's range to 0.0-1.0
                        let normalized_value = if (param_info.max - param_info.min).abs()
                            > f32::EPSILON
                        {
                            ((value as f32 - param_info.min) / (param_info.max - param_info.min))
                                .clamp(0.0, 1.0)
                        } else {
                            0.5 // Fallback for zero-range parameters
                        };

                        // Update cache
                        self.current_param_values.insert(param_id, normalized_value);

                        // Store for status update
                        self.pending_param_changes
                            .push((param_id, normalized_value));

                        tracing::debug!(
                            "Plugin changed parameter {} to {} (CLAP ID: {:?}, denormalized: {:.2})",
                            param_id, normalized_value, clap_id, value
                        );
                    }
                }
            }
        }
    }

    /// Take pending parameter changes (returns and clears the list)
    pub fn take_pending_param_changes(&mut self) -> Vec<(ParamId, ParamValue)> {
        std::mem::take(&mut self.pending_param_changes)
    }

    /// Close the plugin's GUI window
    ///
    /// This must be called on the main thread, not the audio thread.
    pub fn close_gui(&mut self) -> Result<(), String> {
        if !self.gui_open {
            return Ok(()); // Already closed
        }

        // Get the plugin instance handle (instance is always available)
        let mut handle = self.instance.plugin_handle();

        // Try to get the GUI extension
        let Some(gui_ext): Option<PluginGui> = handle.get_extension() else {
            return Err("Plugin does not support GUI extension".to_string());
        };

        // Hide the window first
        let _ = gui_ext.hide(&mut handle); // Ignore errors, might already be hidden

        // Destroy the GUI resources
        gui_ext.destroy(&mut handle);

        self.gui_open = false;
        tracing::info!("Closed GUI for plugin: {}", self.device_name);
        Ok(())
    }

    /// Check if the plugin supports a GUI
    pub fn has_gui(&mut self) -> bool {
        let handle = self.instance.plugin_handle();
        handle.get_extension::<PluginGui>().is_some()
    }

    /// Check if the GUI is currently open
    pub fn is_gui_open(&self) -> bool {
        self.gui_open
    }

    /// Process pending main thread callbacks for the plugin
    ///
    /// This should be called periodically (e.g., from Godot's process loop)
    /// to keep plugin GUIs responsive. This is a temporary solution until
    /// we implement proper per-plugin processes.
    pub fn process_callbacks(&mut self) {
        if self.gui_open {
            self.instance.call_on_main_thread_callback();
        }
    }
}

impl Drop for ClapDeviceAdapter {
    fn drop(&mut self) {
        // Shutdown GUI thread if running
        if self.gui_thread.is_some() {
            self.gui_thread_shutdown.store(true, Ordering::Relaxed);
            if let Some(handle) = self.gui_thread.take() {
                tracing::info!("Waiting for GUI thread to exit for: {}", self.device_name);
                let _ = handle.join(); // Wait for thread to finish
            }
        }

        // Close GUI if it's still open
        if self.gui_open {
            tracing::info!("Closing GUI for plugin on drop: {}", self.device_name);
            let _ = self.close_gui(); // Ignore errors during cleanup
        }

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
