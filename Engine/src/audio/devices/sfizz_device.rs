//! Sfizz SFZ Sample Engine Device
//!
//! Provides built-in SFZ sample playback using the sfizz library.
//! Supports background loading of SFZ files for real-time safety.

use super::{
    AudioDevice, DeviceCategory, DevicePath, DeviceVariant, FileLoadingSupport, MidiPort, ParamId,
    ParamInfo, ParamType, ParamValue, PortFlow,
};
use crate::audio::commands::EngineStatus;
use crossbeam::channel::Sender;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tracing::{error, info};

/// MIDI CCs a host should always expose. Sfizz's `cc_labels()` only returns
/// *named* CCs, which for most SFZs is just the GM Volume/Pan/Expression trio
/// sfizz injects itself. Orchestral libraries (VPO, VSCO, etc.) drive level
/// from unlabeled CC1 (`gain_cc1` / `volume_oncc1`) and would otherwise sit at
/// their padded `volume=` floor with no way to turn them up.
const STANDARD_CC_CONTROLS: &[(u8, &str)] = &[
    (1, "Mod Wheel"),
    (7, "Volume"),
    (10, "Pan"),
    (11, "Expression"),
    (64, "Sustain"),
];

/// Unity gain for the sfizz synth output. Sfizz defaults to -7.35 dB; in a DAW
/// the channel fader is the right place for level.
const SFIZZ_OUTPUT_GAIN_DB: f32 = 0.0;

/// Device-panel P tab: labeled SFZ parameters (including sfizz's GM Volume/Pan/Expression).
const GROUP_PARAM: &str = "param";
/// Device-panel C tab: host-exposed MIDI CCs that the SFZ did not label.
const GROUP_CC: &str = "cc";

/// A MIDI CC exposed as a device parameter, with the UI tab it belongs on.
#[derive(Clone, Debug)]
struct ExposedCc {
    cc_number: u8,
    name: String,
    group: &'static str,
}

/// Wrapper around sfizz::Synth that implements Send
/// Safety: sfizz is thread-safe when properly synchronized via Mutex
struct SendSynth(sfizz::Synth);

/// Render one stereo segment without allocating. `sfizz::Synth::render_block` collects its
/// channel pointers into a `Vec` on every call, so call the C API with a stack array instead.
fn render_stereo(synth: &mut sfizz::Synth, left: &mut [f32], right: &mut [f32]) {
    let frames = left.len().min(right.len());
    if frames == 0 {
        return;
    }
    let mut channels = [left.as_mut_ptr(), right.as_mut_ptr()];
    // SAFETY: `synth` is a live instance borrowed mutably, and both pointers are valid for
    // `frames` samples for the duration of the call.
    unsafe {
        sfizz::sfizz_render_block(synth.as_raw(), channels.as_mut_ptr(), 2, frames as i32);
    }
}
unsafe impl Send for SendSynth {}

/// Loading state for async SFZ file loading
#[derive(Clone)]
enum LoadingState {
    /// No SFZ file loaded
    Idle,
    /// SFZ file is being loaded in background thread
    Loading,
    /// Sfizz synth ready and loaded
    Ready(Arc<Mutex<SendSynth>>),
    /// Failed to load SFZ file
    Failed(String),
}

/// Sfizz SFZ sample engine device
pub struct SfizzDevice {
    // Audio configuration
    sample_rate: f32,
    max_buffer_size: usize,

    // Sfizz synth (wrapped in LoadingState for background loading)
    loading_state: Arc<Mutex<LoadingState>>,

    // Current SFZ file path (for reporting)
    sfz_path: Arc<Mutex<Option<PathBuf>>>,

    // CC parameters (labeled SFZ params + host-exposed MIDI CCs)
    cc_params: Arc<Mutex<Vec<ExposedCc>>>,
    cc_values: Arc<Mutex<HashMap<u8, f32>>>, // CC number -> normalized value (0.0-1.0)

    // Flag to indicate parameters changed (polled by command handler)
    parameters_changed: Arc<Mutex<bool>>,

    // Pre-allocated buffers for planar audio conversion
    left_buffer: Vec<f32>,
    right_buffer: Vec<f32>,

    // Lifecycle state
    is_active: bool,
    is_enabled: bool,

    // Plugin position (for sending loading state notifications)
    channel_id: usize,
    device_path: DevicePath,
    status_tx: Option<Sender<EngineStatus>>,

    // Queued MIDI events (frame-accurate within next block)
    queued_midi: Vec<(usize, u8, u8, bool)>,

    // Pending parameter changes (queued when try_lock fails)
    pending_param_changes: Vec<(u8, f32)>,
}

// Safety: sfizz::Synth contains raw pointers but is thread-safe when used properly
// We ensure thread safety by only accessing it from the audio thread via Mutex
unsafe impl Send for SfizzDevice {}

/// Normalized 0–1 default for a CC after an SFZ load.
///
/// CC7 is forced to 1.0 (sfizz's own default is MIDI 100, which the built-in
/// square-law volume curve turns into ~-4 dB). CC1 is 0.5 to match the common
/// `set_cc1=64` orchestral default so dynamics can still go both ways.
fn default_cc_value(cc_number: u8) -> f32 {
    match cc_number {
        1 => 0.5,
        7 => 1.0,
        10 => 0.5,
        11 => 1.0,
        64 => 0.0,
        _ => 0.5,
    }
}

/// Merge sfizz-reported labels with the standard host CC set.
///
/// Labeled CCs stay on the params tab (`GROUP_PARAM`). Standard CCs the SFZ
/// did not name (typically CC1 / CC64) go on the CC tab (`GROUP_CC`). File
/// names win when both define the same CC.
fn merge_exposed_ccs(sfz_labels: Vec<sfizz::CcLabel>) -> Vec<ExposedCc> {
    let labeled: HashMap<u8, String> = sfz_labels
        .into_iter()
        .map(|label| (label.cc_number, label.name))
        .collect();

    let mut by_cc: BTreeMap<u8, ExposedCc> = BTreeMap::new();
    for &(cc, fallback_name) in STANDARD_CC_CONTROLS {
        let (name, group) = match labeled.get(&cc) {
            Some(file_name) => (file_name.clone(), GROUP_PARAM),
            None => (fallback_name.to_string(), GROUP_CC),
        };
        by_cc.insert(
            cc,
            ExposedCc {
                cc_number: cc,
                name,
                group,
            },
        );
    }
    for (cc, name) in labeled {
        by_cc.entry(cc).or_insert(ExposedCc {
            cc_number: cc,
            name,
            group: GROUP_PARAM,
        });
    }
    by_cc.into_values().collect()
}

/// Send a normalized CC to sfizz. Must not run concurrently with `render_block`.
fn send_normalized_cc(synth: &sfizz::Synth, cc_number: u8, value: f32) {
    unsafe {
        sfizz::sfizz_send_hdcc(synth.as_raw(), 0, cc_number as i32, value);
    }
}

/// Set the synth's output gain in dB. Must not run concurrently with `render_block`.
fn set_synth_output_gain_db(synth: &sfizz::Synth, gain_db: f32) {
    unsafe {
        sfizz::sfizz_set_volume(synth.as_raw(), gain_db);
    }
}

impl SfizzDevice {
    pub fn new(
        sample_rate: f32,
        max_buffer_size: usize,
        channel_id: usize,
        device_path: DevicePath,
        status_tx: Option<Sender<EngineStatus>>,
    ) -> Self {
        info!(
            "Creating SfizzDevice (SR: {}, buffer: {})",
            sample_rate, max_buffer_size
        );

        Self {
            sample_rate,
            max_buffer_size,
            loading_state: Arc::new(Mutex::new(LoadingState::Idle)),
            sfz_path: Arc::new(Mutex::new(None)),
            cc_params: Arc::new(Mutex::new(Vec::new())),
            cc_values: Arc::new(Mutex::new(HashMap::new())),
            parameters_changed: Arc::new(Mutex::new(false)),
            left_buffer: vec![0.0; max_buffer_size],
            right_buffer: vec![0.0; max_buffer_size],
            is_active: true,
            is_enabled: true,
            channel_id,
            device_path,
            status_tx,
            queued_midi: Vec::with_capacity(256),
            pending_param_changes: Vec::new(),
        }
    }

    /// Create a metadata-only instance for device advertisement purposes
    /// This doesn't require runtime parameters like channel_id and status_tx
    pub fn new_for_metadata(sample_rate: f32) -> Self {
        Self::new(sample_rate, 1024, 0, DevicePath::root(0), None)
    }

    /// Check if parameters have changed and clear the flag (poll-based notification)
    /// Called from the audio thread, so a contended lock reports no change and is retried next buffer.
    pub fn take_parameters_changed(&self) -> bool {
        let Ok(mut changed) = self.parameters_changed.try_lock() else {
            return false;
        };
        std::mem::take(&mut *changed)
    }

    /// Queue a parameter change for later (when try_lock fails)
    fn queue_parameter_change(&mut self, cc_number: u8, value: f32) {
        // Remove any existing pending change for this CC
        if let Some(existing) = self
            .pending_param_changes
            .iter()
            .position(|(cc, _)| *cc == cc_number)
        {
            self.pending_param_changes.remove(existing);
        }
        // Add the new value
        self.pending_param_changes.push((cc_number, value));
    }

    /// Flush pending parameter changes to sfizz (called from audio thread)
    /// Returns true if any parameters were flushed
    fn flush_pending_parameters(&mut self) -> bool {
        if self.pending_param_changes.is_empty() {
            return false;
        }

        // Try to get the synth
        let loading_state_result = self.loading_state.try_lock();
        let synth = match loading_state_result {
            Ok(state) => match &*state {
                LoadingState::Ready(synth) => Arc::clone(synth),
                _ => return false, // Not ready, keep pending
            },
            Err(_) => return false, // Can't lock, keep pending
        };

        // Try to lock the synth
        let synth_guard = match synth.try_lock() {
            Ok(guard) => guard,
            Err(_) => return false, // Can't lock, keep pending
        };

        // Successfully got both locks - flush all pending parameters. Cleared in place (no
        // take/drop, no logging): this runs from `process_block` on the audio thread.
        for &(cc_number, value) in &self.pending_param_changes {
            send_normalized_cc(&synth_guard.0, cc_number, value);
        }
        self.pending_param_changes.clear();

        true
    }

    /// Load an SFZ file asynchronously (non-blocking)
    pub fn load_sfz_async(&mut self, path: PathBuf) {
        info!("📂 Loading SFZ file asynchronously: {:?}", path);

        // Update state to Loading
        {
            let mut state = self.loading_state.lock().unwrap();
            *state = LoadingState::Loading;
        }

        // Send loading state
        if let Some(ref tx) = self.status_tx {
            let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                state: "loading".to_string(),
            });
        }

        // Update current path
        {
            let mut sfz_path = self.sfz_path.lock().unwrap();
            *sfz_path = Some(path.clone());
        }

        // Clone Arc references for background thread
        let loading_state = Arc::clone(&self.loading_state);
        let cc_params = Arc::clone(&self.cc_params);
        let cc_values = Arc::clone(&self.cc_values);
        let parameters_changed = Arc::clone(&self.parameters_changed);
        let sample_rate = self.sample_rate;
        let max_buffer_size = self.max_buffer_size;
        let status_tx = self.status_tx.clone();
        let channel_id = self.channel_id;
        let device_path = self.device_path.clone();

        // Spawn background loading thread
        std::thread::spawn(move || {
            info!("🔄 Background thread: Loading SFZ file...");

            // Create sfizz synth
            let synth_result = sfizz::Synth::new();

            match synth_result {
                Ok(mut synth) => {
                    // Configure sample rate and buffer size
                    synth.set_sample_rate(sample_rate);

                    if let Err(e) = synth.set_block_size(max_buffer_size) {
                        error!("❌ Failed to set sfizz block size: {:?}", e);
                        let error_msg = format!("Failed to set block size: {:?}", e);
                        let mut state = loading_state.lock().unwrap();
                        *state = LoadingState::Failed(error_msg.clone());

                        // Send failed state
                        if let Some(ref tx) = status_tx {
                            let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                                channel_id,
                                device_path: device_path.clone(),
                                state: format!("failed:{}", error_msg),
                            });
                        }
                        return;
                    }

                    // Load SFZ file (blocking operation, but on background thread)
                    match synth.load_sfz(&path) {
                        Ok(_) => {
                            info!("✅ SFZ file loaded successfully: {:?}", path);

                            // Unity gain: sfizz's own default is -7.35 dB, which
                            // stacks on top of already-padded orchestral SFZs.
                            set_synth_output_gain_db(&synth, SFIZZ_OUTPUT_GAIN_DB);

                            // Merge file labels with the standard host CC set so
                            // unlabeled dynamics (CC1) are actually controllable.
                            let labels = merge_exposed_ccs(synth.cc_labels());
                            info!(
                                "📋 Exposing {} CC parameters ({} labeled, rest on C tab)",
                                labels.len(),
                                labels.iter().filter(|cc| cc.group == GROUP_PARAM).count()
                            );
                            for label in &labels {
                                info!("  CC{} [{}]: {}", label.cc_number, label.group, label.name);
                            }

                            {
                                let mut cc_params_guard = cc_params.lock().unwrap();
                                *cc_params_guard = labels.clone();
                            }
                            {
                                let mut cc_values_guard = cc_values.lock().unwrap();
                                cc_values_guard.clear();
                                for label in &labels {
                                    let default_value = default_cc_value(label.cc_number);
                                    cc_values_guard.insert(label.cc_number, default_value);
                                    send_normalized_cc(&synth, label.cc_number, default_value);
                                }
                            }

                            // Mark that parameters have changed so they get re-sent to Godot
                            {
                                let mut changed = parameters_changed.lock().unwrap();
                                *changed = true;
                            }

                            // Update state to Ready
                            let mut state = loading_state.lock().unwrap();
                            *state = LoadingState::Ready(Arc::new(Mutex::new(SendSynth(synth))));

                            // Send ready state
                            if let Some(ref tx) = status_tx {
                                let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                                    channel_id,
                                    device_path: device_path.clone(),
                                    state: "ready".to_string(),
                                });
                            }
                        }
                        Err(e) => {
                            error!("❌ Failed to load SFZ file: {:?}", e);
                            let error_msg = format!("Failed to load SFZ: {:?}", e);
                            let mut state = loading_state.lock().unwrap();
                            *state = LoadingState::Failed(error_msg.clone());

                            // Send failed state
                            if let Some(ref tx) = status_tx {
                                let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                                    channel_id,
                                    device_path: device_path.clone(),
                                    state: format!("failed:{}", error_msg),
                                });
                            }
                        }
                    }
                }
                Err(e) => {
                    error!("❌ Failed to create sfizz synth: {:?}", e);
                    let error_msg = format!("Failed to create synth: {:?}", e);
                    let mut state = loading_state.lock().unwrap();
                    *state = LoadingState::Failed(error_msg.clone());

                    // Send failed state
                    if let Some(ref tx) = status_tx {
                        let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                            channel_id,
                            device_path: device_path.clone(),
                            state: format!("failed:{}", error_msg),
                        });
                    }
                }
            }
        });
    }

    /// Get current loading state (for status reporting)
    pub fn get_loading_state_description(&self) -> String {
        let state = self.loading_state.lock().unwrap();
        match &*state {
            LoadingState::Idle => "No SFZ loaded".to_string(),
            LoadingState::Loading => "Loading...".to_string(),
            LoadingState::Ready(_) => {
                let path = self.sfz_path.lock().unwrap();
                if let Some(p) = &*path {
                    format!("Ready: {}", p.display())
                } else {
                    "Ready".to_string()
                }
            }
            LoadingState::Failed(err) => format!("Failed: {}", err),
        }
    }
}

impl AudioDevice for SfizzDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Handle inactive state (device not loaded)
        if !self.is_active {
            // Output silence
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }

        // Handle disabled state (bypassed - pass through silence for instruments)
        if !self.is_enabled {
            // Instruments output silence when bypassed (no input to pass through)
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }

        // Try to flush pending parameters before rendering audio
        // This ensures parameters get applied even if set_parameter couldn't get the lock
        self.flush_pending_parameters();

        // CRITICAL: Check loading state with try_lock (non-blocking!)
        // If we can't get the lock, just output silence (better than blocking)
        let loading_state_result = self.loading_state.try_lock();
        let synth = match loading_state_result {
            Ok(state) => {
                match &*state {
                    LoadingState::Idle => {
                        // No SFZ loaded, output silence
                        for sample in outputs.iter_mut() {
                            *sample = 0.0;
                        }
                        return;
                    }
                    LoadingState::Loading => {
                        // Still loading, output silence
                        for sample in outputs.iter_mut() {
                            *sample = 0.0;
                        }
                        return;
                    }
                    LoadingState::Ready(synth) => {
                        // Clone Arc for use outside this scope
                        Arc::clone(synth)
                    }
                    LoadingState::Failed(_err) => {
                        // Failed to load, output silence
                        for sample in outputs.iter_mut() {
                            *sample = 0.0;
                        }
                        return;
                    }
                }
            }
            Err(_) => {
                // Couldn't get lock (loading in progress), output silence
                for sample in outputs.iter_mut() {
                    *sample = 0.0;
                }
                return;
            }
        };

        // Try to lock the synth (non-blocking)
        let mut synth_guard = match synth.try_lock() {
            Ok(guard) => guard,
            Err(_) => {
                // Couldn't get synth lock, output silence
                for sample in outputs.iter_mut() {
                    *sample = 0.0;
                }
                return;
            }
        };

        // Prepare planar buffers for sfizz (it expects separate L/R channels)
        // We'll render in segments to honor frame-accurate MIDI
        self.left_buffer[..sample_count].fill(0.0);
        self.right_buffer[..sample_count].fill(0.0);

        // Sort in place and clear afterwards so the queue keeps its preallocated capacity.
        // Same-frame events: note-off before note-on so a retrigger isn't killed by a later off.
        self.queued_midi
            .sort_unstable_by(|a, b| a.0.cmp(&b.0).then(a.3.cmp(&b.3)));

        let mut cursor = 0usize;
        for i in 0..self.queued_midi.len() {
            let (offset, note, velocity, is_on) = self.queued_midi[i];
            let clamped_offset = std::cmp::min(offset, sample_count);
            if clamped_offset > cursor {
                render_stereo(
                    &mut synth_guard.0,
                    &mut self.left_buffer[cursor..clamped_offset],
                    &mut self.right_buffer[cursor..clamped_offset],
                );
                cursor = clamped_offset;
            }

            // Apply event exactly at this frame
            if is_on {
                synth_guard.0.note_on(note, velocity);
            } else {
                synth_guard.0.note_off(note, velocity);
            }
        }
        self.queued_midi.clear();

        // Render the remainder of the buffer after the last event
        if cursor < sample_count {
            render_stereo(
                &mut synth_guard.0,
                &mut self.left_buffer[cursor..sample_count],
                &mut self.right_buffer[cursor..sample_count],
            );
        }

        // Convert from planar to interleaved stereo
        for i in 0..sample_count {
            let left_idx = i * 2;
            let right_idx = i * 2 + 1;
            if left_idx < outputs.len() {
                outputs[left_idx] = self.left_buffer[i];
            }
            if right_idx < outputs.len() {
                outputs[right_idx] = self.right_buffer[i];
            }
        }
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        // Queue event for sample-accurate application in next process_block
        self.queued_midi
            .push((frame_offset, note, velocity, is_note_on));
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        // ParamId is the CC number
        let cc_number = param_id as u8;

        info!(
            "🎛️  SfizzDevice::set_parameter CC{} = {} (channel={}, pos={})",
            cc_number, value, self.channel_id, self.device_path
        );

        // Store the value
        {
            let mut cc_values = self.cc_values.lock().unwrap();
            cc_values.insert(cc_number, value);
        }

        // Try to flush any previously pending parameters first
        self.flush_pending_parameters();

        // Send to sfizz synth (non-blocking)
        // Check synth ready state and clone Arc if ready
        let synth_option = {
            match self.loading_state.try_lock() {
                Ok(state) => match &*state {
                    LoadingState::Ready(synth) => Some(Arc::clone(synth)),
                    _ => None,
                },
                Err(_) => None,
            }
        };

        let synth = match synth_option {
            Some(s) => {
                info!("  ✓ Synth is ready, proceeding to send HDCC");
                s
            }
            None => {
                info!("  ⚠ Synth not ready or locked, parameter queued");
                self.queue_parameter_change(cc_number, value);
                return;
            }
        };

        // Try to lock the synth (non-blocking)
        let synth_guard = match synth.try_lock() {
            Ok(guard) => guard,
            Err(_) => {
                info!("  ⚠ Could not lock synth, parameter queued");
                self.queue_parameter_change(cc_number, value);
                return;
            }
        };

        send_normalized_cc(&synth_guard.0, cc_number, value);
        info!("  ✅ HDCC sent to sfizz: CC{} = {}", cc_number, value);
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        let cc_number = param_id as u8;
        let cc_values = self.cc_values.lock().unwrap();
        cc_values.get(&cc_number).copied()
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.sfizz"
    }

    fn device_name(&self) -> &str {
        "Sfizz SFZ Sampler"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Instrument
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn file_loading_support(&self) -> Option<FileLoadingSupport> {
        Some(FileLoadingSupport {
            description: "SFZ Sample Files".to_string(),
            extensions: vec![".sfz".to_string(), ".SFZ".to_string()],
        })
    }

    fn midi_ports(&self) -> Vec<MidiPort> {
        vec![MidiPort {
            id: 0,
            name: "MIDI In".to_string(),
            flow: PortFlow::Input,
        }]
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        let cc_params = self.cc_params.lock().unwrap();

        cc_params
            .iter()
            .map(|label| {
                let default = default_cc_value(label.cc_number);

                ParamInfo {
                    id: label.cc_number as ParamId,
                    name: label.name.clone(),
                    unit: String::new(),
                    min: 0.0,
                    max: 1.0,
                    default,
                    is_automation_safe: true,
                    is_hidden: false,
                    is_read_only: false,
                    is_bypass: false,
                    module: String::new(),
                    param_type: ParamType::Float,
                    syncable: true,
                    enum_values: Vec::new(),
                }
            })
            .collect()
    }

    /// Look up whether this CC belongs on the params tab or the CC tab.
    fn parameter_group(&self, param_id: ParamId) -> &'static str {
        let cc_params = self.cc_params.lock().unwrap();
        cc_params
            .iter()
            .find(|cc| cc.cc_number as ParamId == param_id)
            .map(|cc| cc.group)
            .unwrap_or(GROUP_PARAM)
    }

    /// Command thread, stream stopped: retune a loaded synth to the new rate. An SFZ still
    /// loading keeps the rate it started with; later `load_sfz_async` calls use the new one.
    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        let state = self
            .loading_state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let LoadingState::Ready(synth) = &*state {
            let mut synth = synth
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            synth.0.set_sample_rate(sample_rate);
        }
    }

    fn reset(&mut self) {
        // Try to get loading state (non-blocking)
        let loading_state_result = self.loading_state.try_lock();
        let synth = match loading_state_result {
            Ok(state) => {
                match &*state {
                    LoadingState::Ready(synth) => Arc::clone(synth),
                    _ => return, // Not ready, nothing to reset
                }
            }
            Err(_) => return, // Can't get lock, skip reset
        };

        // Try to lock the synth (non-blocking)
        let mut synth_guard = match synth.try_lock() {
            Ok(guard) => guard,
            Err(_) => return, // Can't get synth lock, skip reset
        };

        // Silence all notes
        // Access inner Synth via .0
        synth_guard.0.all_sound_off();
    }

    // === Lifecycle Management ===

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        self.is_active = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.is_active = false;

        // Clear loading state to free memory
        {
            let mut state = self.loading_state.lock().unwrap();
            *state = LoadingState::Idle;
        }

        // Clear CC parameters
        {
            let mut cc_params = self.cc_params.lock().unwrap();
            cc_params.clear();
        }
        {
            let mut cc_values = self.cc_values.lock().unwrap();
            cc_values.clear();
        }
        {
            let mut changed = self.parameters_changed.lock().unwrap();
            *changed = false;
        }

        Ok(())
    }

    // === Bypass Control ===

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labeled_ccs_stay_on_param_tab_unlabeled_standards_go_to_cc_tab() {
        // Typical sfizz output: GM Volume/Pan/Expression are always labeled.
        let merged = merge_exposed_ccs(vec![
            sfizz::CcLabel {
                cc_number: 7,
                name: "Volume".to_string(),
            },
            sfizz::CcLabel {
                cc_number: 10,
                name: "Pan".to_string(),
            },
            sfizz::CcLabel {
                cc_number: 11,
                name: "Expression".to_string(),
            },
            sfizz::CcLabel {
                cc_number: 74,
                name: "Brightness".to_string(),
            },
        ]);
        let by_cc: HashMap<u8, &ExposedCc> = merged.iter().map(|cc| (cc.cc_number, cc)).collect();

        assert_eq!(by_cc[&1].name, "Mod Wheel");
        assert_eq!(by_cc[&1].group, GROUP_CC);
        assert_eq!(by_cc[&7].name, "Volume");
        assert_eq!(by_cc[&7].group, GROUP_PARAM);
        assert_eq!(by_cc[&10].group, GROUP_PARAM);
        assert_eq!(by_cc[&11].group, GROUP_PARAM);
        assert_eq!(by_cc[&64].name, "Sustain");
        assert_eq!(by_cc[&64].group, GROUP_CC);
        assert_eq!(by_cc[&74].name, "Brightness");
        assert_eq!(by_cc[&74].group, GROUP_PARAM);
    }

    #[test]
    fn volume_and_expression_default_to_full_scale() {
        assert_eq!(default_cc_value(1), 0.5);
        assert_eq!(default_cc_value(7), 1.0);
        assert_eq!(default_cc_value(11), 1.0);
        assert_eq!(default_cc_value(64), 0.0);
    }
}
