use crossbeam::channel::Sender;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::time::Instant;
use tracing::{info, warn};

use super::devices::DevicePath;
use super::render_scratch::RenderScratch;
use super::types::*;

/// Parameter information for builtin devices
#[derive(Debug, Clone)]
pub struct BuiltinParamInfo {
    pub id: u32,
    pub name: String,
    pub unit: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub param_type: super::devices::ParamType,
    pub syncable: bool,
    pub enum_values: Vec<String>,
}

/// Commands that can be sent to the audio engine
#[derive(Debug, Clone)]
pub enum AudioCommand {
    // Project management
    InitProject(ProjectSettings),
    ClearProject,

    // Transport control
    Play,
    Pause,
    Stop,
    Seek(Tick),
    SetTempo(f32),
    SetTimeSignature(i32, i32),

    // Channel management
    CreateChannel {
        id: ChannelId,
        name: String,
    },
    RemoveChannel {
        id: ChannelId,
    },
    SetChannelVolume {
        id: ChannelId,
        db: f32,
    },
    SetChannelPan {
        id: ChannelId,
        pan_left: f32,
        pan_right: Option<f32>,
    },
    SetChannelPanMode {
        id: ChannelId,
        mode: i32,
    },
    SetChannelMute {
        id: ChannelId,
        mute: bool,
    },
    SetChannelSolo {
        id: ChannelId,
        solo: bool,
    },
    SetChannelRoute {
        id: ChannelId,
        output_id: Option<ChannelId>,
    },
    /// Map extra device bus `bus_index` on `id` to `target_id` (0 clears the mapping).
    SetAuxOut {
        id: ChannelId,
        bus_index: usize,
        target_id: ChannelId,
    },

    // MIDI routing
    SetMidiInputDevice {
        channel_id: ChannelId,
        device_id: i32,
    },
    SetRecordArmed {
        channel_id: ChannelId,
        armed: bool,
    },
    MidiEvent {
        channel_id: ChannelId,
        message_type: u8,
        midi_channel: u8,
        note: u8,
        velocity: u8,
        /// When the OSC server received the event; used to place it within the audio buffer
        received_at: Instant,
    },

    // Send management
    AddSend {
        channel_id: ChannelId,
        target_channel_id: ChannelId,
        amount_db: f32,
        pre_fader: bool,
    },
    RemoveSend {
        channel_id: ChannelId,
        target_channel_id: ChannelId,
    },
    SetSendAmount {
        channel_id: ChannelId,
        target_channel_id: ChannelId,
        amount_db: f32,
    },
    SetSendPreFader {
        channel_id: ChannelId,
        target_channel_id: ChannelId,
        pre_fader: bool,
    },
    SetSendMute {
        channel_id: ChannelId,
        target_channel_id: ChannelId,
        muted: bool,
    },

    // Track management
    CreateTrack {
        id: TrackId,
        channel_id: ChannelId,
    },
    SetTrackRoute {
        id: TrackId,
        channel_id: ChannelId,
    },

    // Clip management (new architecture)
    CreateClip {
        id: ClipId,
        name: String,
        clip_type: String,
    },
    RemoveClip {
        id: ClipId,
    },
    AddNoteToClip {
        clip_id: ClipId,
        note_id: NoteId,
        note: MidiNote,
        start_tick: Tick,
        duration_ticks: Tick,
        velocity: MidiVelocity,
    },
    RemoveNoteFromClip {
        clip_id: ClipId,
        note_id: NoteId,
    },
    UpdateClipNote {
        clip_id: ClipId,
        note_id: NoteId,
        note: MidiNote,
        start_tick: Tick,
        duration_ticks: Tick,
        velocity: MidiVelocity,
    },
    BeginLoadAudioClip {
        clip_id: ClipId,
        req_id: String,
        source_path: String,
    },
    LoadAudioClip {
        clip_id: ClipId,
        req_id: String,
        source_path: String,
        cache_key: Option<String>,
        samples: Vec<f32>,
        sample_rate: u32,
        channels: usize,
    },
    FailAudioClipLoad {
        clip_id: ClipId,
        req_id: String,
        message: String,
    },

    // ClipInstance management
    CreateClipInstance {
        track_id: TrackId,
        instance_id: ClipInstanceId,
        clip_id: ClipId,
        start_tick: Tick,
        duration_ticks: Tick,
    },
    RemoveClipInstance {
        track_id: TrackId,
        instance_id: ClipInstanceId,
    },
    UpdateClipInstancePosition {
        track_id: TrackId,
        instance_id: ClipInstanceId,
        start_tick: Tick,
        duration_ticks: Tick,
        clip_offset: Tick,
    },
    UpdateClipInstanceTranspose {
        track_id: TrackId,
        instance_id: ClipInstanceId,
        transpose: i8,
    },
    UpdateClipInstanceGain {
        track_id: TrackId,
        instance_id: ClipInstanceId,
        gain_db: f32,
    },
    UpdateClipInstanceMute {
        track_id: TrackId,
        instance_id: ClipInstanceId,
        muted: bool,
    },
    UpdateClipInstanceLoop {
        track_id: TrackId,
        instance_id: ClipInstanceId,
        enabled: bool,
        start_tick: Tick,
        length_ticks: Tick,
    },

    // Device management
    AddDeviceToChannel {
        channel_id: ChannelId,
        parent_path: DevicePath,
        device_id: String,
        device_type: String, // "builtin", "clap", "lv2", "vst3"
        device_file: String, // Path to plugin file (empty for built-ins)
        position: i32,
        active: bool,
        enabled: bool,
    },
    RemoveDeviceFromChannel {
        channel_id: ChannelId,
        parent_path: DevicePath,
        position: usize,
    },
    MoveDevice {
        channel_id: ChannelId,
        parent_path: DevicePath,
        from_position: usize,
        to_position: usize,
    },
    ClearChannelDevices {
        channel_id: ChannelId,
    },
    SetDeviceParameter {
        channel_id: ChannelId,
        device_path: DevicePath,
        param_id: u32,
        value: super::types::ParamSetValue,
    },
    SetDeviceActive {
        channel_id: ChannelId,
        device_path: DevicePath,
        active: bool,
    },
    SetDeviceEnabled {
        channel_id: ChannelId,
        device_path: DevicePath,
        enabled: bool,
    },
    LoadDeviceFile {
        channel_id: ChannelId,
        device_path: DevicePath,
        file_path: String,
    },
    BeginLoadDeviceSample {
        channel_id: ChannelId,
        device_path: DevicePath,
        req_id: String,
    },
    LoadDeviceSample {
        channel_id: ChannelId,
        device_path: DevicePath,
        req_id: String,
        samples: Vec<f32>,
        sample_rate: u32,
        channels: usize,
    },
    FailDeviceSampleLoad {
        channel_id: ChannelId,
        device_path: DevicePath,
        req_id: String,
        message: String,
    },
    DeviceReady {
        channel_id: ChannelId,
        device_path: DevicePath,
    },

    // Plugin management
    ScanPlugins,
    AdvertiseBuiltinDevices,
    GetPluginParameters {
        channel_id: ChannelId,
        device_path: DevicePath,
    },
    SavePluginState {
        channel_id: ChannelId,
        device_path: DevicePath,
    },
    LoadPluginState {
        channel_id: ChannelId,
        device_path: DevicePath,
        state_base64: String,
    },

    // Plugin GUI
    OpenPluginGui {
        channel_id: ChannelId,
        device_path: DevicePath,
        window_handle: Option<u64>,
    },

    ClosePluginGui {
        channel_id: ChannelId,
        device_path: DevicePath,
    },

    // Device data subscriptions
    SubscribeDeviceData {
        channel_id: ChannelId,
        device_path: DevicePath,
        data_type: String, // "spectrum", "oscilloscope", "phase", etc.
    },
    UnsubscribeDeviceData {
        channel_id: ChannelId,
        device_path: DevicePath,
        data_type: String,
    },
    SetLayerSlotVolume {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        volume: f32,
    },
    SetLayerSlotMute {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        mute: bool,
    },
    SetLayerSlotSolo {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        solo: bool,
    },
    SetDrumSlotNote {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        note: u8,
    },
}

/// Response from commands that return data
#[derive(Debug, Clone)]
pub enum CommandResponse {
    NoteAdded(NoteId),
}

/// Status updates from audio thread
#[derive(Debug, Clone)]
pub enum EngineStatus {
    PlayheadUpdate(Tick),
    PlayingStateChanged(bool),
    ChannelPeaks {
        id: ChannelId,
        peak_left: f32,
        peak_right: f32,
        rms_left: f32,
        rms_right: f32,
    },
    ClipLoadStateChanged {
        clip_id: ClipId,
        state: ClipLoadState,
        source_path: Option<String>,
        cache_key: Option<String>,
        sample_rate: Option<u32>,
        channels: Option<usize>,
    },

    // Device state changes
    DeviceActiveChanged {
        channel_id: ChannelId,
        device_path: DevicePath,
        active: bool,
    },
    DeviceEnabledChanged {
        channel_id: ChannelId,
        device_path: DevicePath,
        enabled: bool,
    },
    DeviceReady {
        channel_id: ChannelId,
        device_path: DevicePath,
    },
    DeviceLoadingStateChanged {
        channel_id: ChannelId,
        device_path: DevicePath,
        state: String, // "idle", "loading", "ready", "failed:{error}"
    },

    // Plugin GUI events
    PluginGuiResizeRequest {
        channel_id: ChannelId,
        device_path: DevicePath,
        width: u32,
        height: u32,
    },
    PluginGuiClosed {
        channel_id: ChannelId,
        device_path: DevicePath,
    },

    // Plugin discovery responses
    PluginScanComplete {
        count: usize,
    },
    PluginInfo {
        id: String,
        name: String,
        vendor: String,
        version: String,
        category: String,
        description: Option<String>,
        path: String, // Path to plugin file
    },

    // Builtin device advertisement
    BuiltinDeviceInfo {
        id: String,
        name: String,
        category: String,
        description: String,
        accepts_midi: bool,
        audio_in_channels: usize,
        audio_out_channels: usize,
        supports_file_loading: bool,
        file_extensions: Vec<String>,
        file_type_description: String,
        is_container: bool,
        parameters: Vec<BuiltinParamInfo>,
    },
    BuiltinDevicesComplete {
        count: usize,
    },

    // Plugin parameter responses
    PluginParameterInfo {
        channel_id: ChannelId,
        device_path: DevicePath,
        param_id: u32,
        name: String,
        min: f32,
        max: f32,
        default: f32,
        /// `"param"` for the P tab, `"cc"` for the C tab.
        group: String,
    },
    PluginParameterCount {
        channel_id: ChannelId,
        device_path: DevicePath,
        count: usize,
    },

    // Plugin state responses
    PluginStateSaved {
        channel_id: ChannelId,
        device_path: DevicePath,
        state_base64: String,
    },

    // Plugin parameter value changes (from plugin GUI or internal modulation)
    PluginParameterValueChanged {
        channel_id: ChannelId,
        device_path: DevicePath,
        param_id: u32,
        value: f32, // Normalized 0.0-1.0
    },

    // Log messages forwarded to Godot UI
    LogMessage {
        level: String, // "warn" or "error"
        message: String,
    },

    // Performance metrics
    EngineLoad {
        load: f32, // CPU load as ratio (0.0-1.0+, where 1.0 = 100% utilization)
    },

    // Device data subscriptions
    DeviceData {
        channel_id: ChannelId,
        device_path: DevicePath,
        data_type: String, // "spectrum", "oscilloscope", "phase", etc.
        data: Vec<u8>,     // Binary payload (device-specific format)
    },

    // Device sleep/wake status (CPU optimization)
    DeviceSleepStatus {
        channel_id: ChannelId,
        device_path: DevicePath,
        is_sleeping: bool, // true = device sleeping (saving CPU), false = device active
    },
}

impl EngineStatus {
    /// Check if this status is a parameter change (for debug logging)
    pub fn is_param_change(&self) -> bool {
        matches!(self, EngineStatus::PluginParameterValueChanged { .. })
    }
}

/// Shared state between audio thread and command thread
pub struct EngineState {
    pub settings: ProjectSettings,
    pub device_sample_rate: f32, // Actual audio device sample rate (immutable)
    pub channels: HashMap<ChannelId, Channel>,
    pub tracks: HashMap<TrackId, Track>,
    pub clips: HashMap<ClipId, Clip>,      // Global clip pool
    pub output_devices: Vec<OutputDevice>, // Available hardware outputs (IDs 1000+)
    /// Preallocated scratch lists so the audio callback doesn't allocate
    pub render_scratch: RenderScratch,
    pub is_playing: AtomicBool,
    pub current_tick: AtomicI64,
    /// Fractional tick accumulator carried across buffers for sample-accurate scheduling (stored as fixed-point * 1e9)
    pub fractional_tick_accumulator: AtomicI64,
    /// When true, the next playing callback dispatches MIDI at the playhead tick (play/seek).
    pub dispatch_playhead_tick: AtomicBool,
}

impl EngineState {
    /// Get the current tick (lock-free)
    pub fn get_current_tick(&self) -> Tick {
        self.current_tick.load(Ordering::Acquire) as Tick
    }

    /// Set the current tick (lock-free)
    pub fn set_current_tick(&self, tick: Tick) {
        self.current_tick.store(tick as i64, Ordering::Release);
    }

    /// Get the fractional tick accumulator (lock-free)
    pub fn get_fractional_tick_accumulator(&self) -> f64 {
        self.fractional_tick_accumulator.load(Ordering::Acquire) as f64 / 1_000_000_000.0
    }

    /// Set the fractional tick accumulator (lock-free)
    pub fn set_fractional_tick_accumulator(&self, value: f64) {
        self.fractional_tick_accumulator
            .store((value * 1_000_000_000.0) as i64, Ordering::Release);
    }

    /// Get playing state (lock-free)
    pub fn get_is_playing(&self) -> bool {
        self.is_playing.load(Ordering::Acquire)
    }

    /// Set playing state (lock-free)
    pub fn set_is_playing(&self, playing: bool) {
        self.is_playing.store(playing, Ordering::Release);
    }

    /// Ask the next playing callback to fire clip MIDI at the current playhead tick.
    pub fn request_playhead_midi_dispatch(&self) {
        self.dispatch_playhead_tick.store(true, Ordering::Release);
    }

    /// Consume the playhead MIDI dispatch flag. True only for the first buffer after play/seek.
    pub fn take_playhead_midi_dispatch(&self) -> bool {
        self.dispatch_playhead_tick.swap(false, Ordering::AcqRel)
    }

    /// Create master (ID 1) routed to the default hardware output if it is missing.
    ///
    /// Without this, a Godot session that outlives an engine restart still routes tracks to
    /// channel 1, but that channel does not exist: meters stay at zero and the CPAL buffer
    /// stays silent.
    pub fn ensure_master_channel(&mut self, buffer_size: usize) {
        if self.channels.contains_key(&1) {
            return;
        }
        let mut master = Channel::new(
            1,
            "Master".to_string(),
            buffer_size,
            self.device_sample_rate,
        );
        master.output_channel_id = Some(1000);
        self.channels.insert(1, master);
        info!("Master channel created (hardware output 1000)");
    }
}

impl Clone for EngineState {
    fn clone(&self) -> Self {
        // Can't derive Clone because Channel has trait objects (AudioDevice)
        // This is only used for command processing, which we don't use Clone for
        panic!("EngineState cannot be cloned (contains non-cloneable trait objects)");
    }
}

impl Default for EngineState {
    fn default() -> Self {
        Self {
            settings: ProjectSettings::default(),
            device_sample_rate: 48000.0, // Default, will be overridden
            channels: HashMap::new(),
            tracks: HashMap::new(),
            clips: HashMap::new(),
            output_devices: Vec::new(),
            render_scratch: RenderScratch::default(),
            is_playing: AtomicBool::new(false),
            current_tick: AtomicI64::new(0),
            fractional_tick_accumulator: AtomicI64::new(0),
            dispatch_playhead_tick: AtomicBool::new(false),
        }
    }
}

/// Apply a command to the engine state. Runs on the command thread with the state lock held, so
/// it must stay fast; slow commands are handled by `CommandWorker` instead.
pub fn process_command(
    state: &mut EngineState,
    cmd: AudioCommand,
    buffer_size: usize,
    status_tx: &Sender<EngineStatus>,
) -> Option<EngineStatus> {
    match cmd {
        AudioCommand::InitProject(mut settings) => {
            let device_sr = state.device_sample_rate.round() as i32;
            if (settings.sample_rate - device_sr).abs() > 1 {
                info!(
                    "Project sample rate {} overridden to match device {}",
                    settings.sample_rate, device_sr
                );
            }
            settings.sample_rate = device_sr;
            state.settings = settings;
            state.ensure_master_channel(buffer_size);
            info!(
                "Project initialized: {}bpm, {}/{}, PPQ={}, SR={} (device)",
                state.settings.tempo,
                state.settings.time_numerator,
                state.settings.time_denominator,
                state.settings.ppq,
                device_sr
            );
        }
        AudioCommand::Play => {
            state.set_is_playing(true);
            state.request_playhead_midi_dispatch();
            let position = state
                .settings
                .format_tick_position(state.get_current_tick());
            info!("Playback started at {}", position);
            return Some(EngineStatus::PlayingStateChanged(true));
        }
        AudioCommand::Pause => {
            state.set_is_playing(false);
            let position = state
                .settings
                .format_tick_position(state.get_current_tick());
            // Reset all devices to stop any playing notes/voices
            for channel in state.channels.values_mut() {
                channel.active_voices.clear();
                for device in &mut channel.devices {
                    device.reset();
                }
            }
            info!("Playback paused at {}", position);
            return Some(EngineStatus::PlayingStateChanged(false));
        }
        AudioCommand::Stop => {
            let position = state
                .settings
                .format_tick_position(state.get_current_tick());
            state.set_is_playing(false);
            state.set_current_tick(0);
            state.set_fractional_tick_accumulator(0.0);
            state.dispatch_playhead_tick.store(false, Ordering::Release);
            // Reset all channels and tracks
            for channel in state.channels.values_mut() {
                channel.active_voices.clear();
                channel.scheduled_midi_events.clear();
                for device in &mut channel.devices {
                    device.reset();
                }
            }
            for track in state.tracks.values_mut() {
                track.audio_playback_positions.clear();
            }
            info!("Playback stopped (was at {})", position);
            // Send both playing state change and playhead reset
            // Note: only one status can be returned, so we'll send playhead via the channel
            // and return playing state
            let _ = status_tx.send(EngineStatus::PlayheadUpdate(0));
            return Some(EngineStatus::PlayingStateChanged(false));
        }
        AudioCommand::Seek(tick) => {
            state.set_current_tick(tick);
            state.set_fractional_tick_accumulator(0.0);
            state.request_playhead_midi_dispatch();
            // Reset all channels and tracks on seek
            for channel in state.channels.values_mut() {
                channel.active_voices.clear();
                for device in &mut channel.devices {
                    device.reset();
                }
            }
            for track in state.tracks.values_mut() {
                track.audio_playback_positions.clear();
            }
            info!("Seeked to tick {}", tick);
        }
        AudioCommand::SetTempo(tempo) => {
            state.settings.tempo = tempo;
            info!("Tempo set to {}", tempo);
        }
        AudioCommand::SetTimeSignature(num, den) => {
            state.settings.time_numerator = num;
            state.settings.time_denominator = den;
            info!("Time signature set to {}/{}", num, den);
        }
        AudioCommand::CreateChannel { id, name } => {
            let channel = Channel::new(id, name.clone(), buffer_size, state.device_sample_rate);
            state.channels.insert(id, channel);
            info!(
                "Channel {} created: {} [total channels: {}]",
                id,
                name,
                state.channels.len()
            );
        }
        AudioCommand::SetChannelVolume { id, db } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                channel.volume_db = db;
            }
        }
        AudioCommand::SetChannelPan {
            id,
            pan_left,
            pan_right,
        } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                if let Some(pan_r) = pan_right {
                    // Dual pan mode (STEREO_DUAL)
                    channel.pan_left = pan_left.clamp(-1.0, 1.0);
                    channel.pan_right = pan_r.clamp(-1.0, 1.0);
                } else {
                    // Single pan value (STEREO_COMBINED, STEREO_BALANCE, MONO)
                    channel.pan = pan_left.clamp(-1.0, 1.0);
                }
            }
        }
        AudioCommand::SetChannelPanMode { id, mode } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                channel.pan_mode = mode.into();
            }
        }
        AudioCommand::SetChannelMute { id, mute } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                channel.mute = mute;
            }
        }
        AudioCommand::SetChannelSolo { id, solo } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                channel.solo = solo;
            }
        }
        AudioCommand::SetChannelRoute { id, output_id } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                channel.output_channel_id = output_id;
                info!("Channel {} routed to {:?}", id, output_id);
            } else {
                warn!("Cannot set route for channel {} (not found)", id);
            }
        }
        AudioCommand::SetAuxOut {
            id,
            bus_index,
            target_id,
        } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                channel.set_aux_out(bus_index, target_id);
                info!("Channel {} extra out {} -> {}", id, bus_index, target_id);
            } else {
                warn!("Cannot set aux out for channel {} (not found)", id);
            }
        }

        // MIDI routing commands
        AudioCommand::SetMidiInputDevice {
            channel_id,
            device_id,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                channel.midi_routing.device_id = device_id;
                info!(
                    "Channel {} MIDI input device set to {}",
                    channel_id, device_id
                );
            } else {
                warn!(
                    "Cannot set MIDI input device for channel {} (not found)",
                    channel_id
                );
            }
        }

        AudioCommand::SetRecordArmed { channel_id, armed } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                channel.midi_routing.record_armed = armed;
                info!("Channel {} record armed: {}", channel_id, armed);
            } else {
                warn!(
                    "Cannot set record armed for channel {} (not found)",
                    channel_id
                );
            }
        }

        AudioCommand::MidiEvent {
            channel_id,
            message_type,
            midi_channel,
            note,
            velocity,
            received_at,
        } => {
            use super::midi_types::{MidiEvent, MidiMessageType};

            if let Some(channel) = state.channels.get(&channel_id) {
                // Convert message type
                if let Some(msg_type) = MidiMessageType::from_u8(message_type) {
                    // The audio thread turns received_at into a frame offset
                    let event = MidiEvent {
                        message_type: msg_type,
                        midi_channel,
                        note,
                        velocity,
                        received_at,
                        frame_offset: 0,
                    };

                    // Push to channel's MIDI queue (lock-free)
                    channel.midi_queue.push(event);
                } else {
                    warn!("Unknown MIDI message type: {}", message_type);
                }
            } else {
                warn!(
                    "Cannot send MIDI event to channel {} (not found)",
                    channel_id
                );
            }
        }

        // Send management commands
        AudioCommand::AddSend {
            channel_id,
            target_channel_id,
            amount_db,
            pre_fader,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                // Check if send already exists to this target
                if channel
                    .send_channels
                    .iter()
                    .any(|s| s.target_channel_id == target_channel_id)
                {
                    warn!(
                        "Send from channel {} to {} already exists",
                        channel_id, target_channel_id
                    );
                } else {
                    channel.send_channels.push(super::types::Send {
                        target_channel_id,
                        amount_db,
                        pre_fader,
                        muted: false,
                    });
                    info!(
                        "Send added: channel {} -> {} ({:.1} dB, {})",
                        channel_id,
                        target_channel_id,
                        amount_db,
                        if pre_fader { "pre-fader" } else { "post-fader" }
                    );
                }
            } else {
                warn!("Cannot add send: channel {} not found", channel_id);
            }
        }
        AudioCommand::RemoveSend {
            channel_id,
            target_channel_id,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                let initial_len = channel.send_channels.len();
                channel
                    .send_channels
                    .retain(|s| s.target_channel_id != target_channel_id);
                if channel.send_channels.len() != initial_len {
                    info!(
                        "Send removed: channel {} -> {}",
                        channel_id, target_channel_id
                    );
                } else {
                    warn!(
                        "Send not found: channel {} -> {}",
                        channel_id, target_channel_id
                    );
                }
            } else {
                warn!("Cannot remove send: channel {} not found", channel_id);
            }
        }
        AudioCommand::SetSendAmount {
            channel_id,
            target_channel_id,
            amount_db,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(send) = channel
                    .send_channels
                    .iter_mut()
                    .find(|s| s.target_channel_id == target_channel_id)
                {
                    send.amount_db = amount_db.clamp(-60.0, 12.0);
                    // Don't log every parameter change (too noisy)
                } else {
                    warn!(
                        "Cannot set send amount: send not found (channel {} -> {})",
                        channel_id, target_channel_id
                    );
                }
            } else {
                warn!("Cannot set send amount: channel {} not found", channel_id);
            }
        }
        AudioCommand::SetSendPreFader {
            channel_id,
            target_channel_id,
            pre_fader,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(send) = channel
                    .send_channels
                    .iter_mut()
                    .find(|s| s.target_channel_id == target_channel_id)
                {
                    send.pre_fader = pre_fader;
                    info!(
                        "Send pre-fader set: channel {} -> {} ({})",
                        channel_id,
                        target_channel_id,
                        if pre_fader { "pre" } else { "post" }
                    );
                } else {
                    warn!(
                        "Cannot set send pre-fader: send not found (channel {} -> {})",
                        channel_id, target_channel_id
                    );
                }
            } else {
                warn!(
                    "Cannot set send pre-fader: channel {} not found",
                    channel_id
                );
            }
        }
        AudioCommand::SetSendMute {
            channel_id,
            target_channel_id,
            muted,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(send) = channel
                    .send_channels
                    .iter_mut()
                    .find(|s| s.target_channel_id == target_channel_id)
                {
                    send.muted = muted;
                    info!(
                        "Send mute set: channel {} -> {} ({})",
                        channel_id,
                        target_channel_id,
                        if muted { "muted" } else { "unmuted" }
                    );
                } else {
                    warn!(
                        "Cannot set send mute: send not found (channel {} -> {})",
                        channel_id, target_channel_id
                    );
                }
            } else {
                warn!("Cannot set send mute: channel {} not found", channel_id);
            }
        }
        AudioCommand::CreateTrack { id, channel_id } => {
            let track = Track::new(id, channel_id);
            state.tracks.insert(id, track);
            info!("Track {} created, routed to channel {}", id, channel_id);
        }
        AudioCommand::SetTrackRoute { id, channel_id } => {
            if let Some(track) = state.tracks.get_mut(&id) {
                track.channel_id = channel_id;
                info!("Track {} routed to channel {}", id, channel_id);
            } else {
                warn!("Cannot set route for track {} (not found)", id);
            }
        }

        // Clip management commands
        AudioCommand::CreateClip {
            id,
            name,
            clip_type,
        } => {
            use super::types::ClipType;
            let clip_type_enum = match clip_type.as_str() {
                "midi" | "Midi" => ClipType::Midi,
                "audio" | "Audio" => ClipType::Audio,
                _ => {
                    warn!("Unknown clip type: {}, defaulting to Midi", clip_type);
                    ClipType::Midi
                }
            };
            let clip = Clip::new(id.clone(), name.clone(), clip_type_enum);
            state.clips.insert(id.clone(), clip);
            info!("Clip created: {} ({})", name, id);
        }
        AudioCommand::RemoveClip { id } => {
            if state.clips.remove(&id).is_some() {
                info!("Clip removed: {}", id);
            } else {
                warn!("Clip not found for removal: {}", id);
            }
        }
        AudioCommand::AddNoteToClip {
            clip_id,
            note_id,
            note,
            start_tick,
            duration_ticks,
            velocity,
        } => {
            if let Some(clip) = state.clips.get_mut(&clip_id) {
                // Check if note with this ID already exists (protect against duplicate OSC messages)
                if clip.midi_notes.iter().any(|n| n.id == note_id) {
                    warn!(
                        "Note {} already exists in clip {} - ignoring duplicate add command",
                        note_id, clip_id
                    );
                } else {
                    let clip_note = ClipNote {
                        id: note_id,
                        note,
                        velocity,
                        start_tick,
                        duration_ticks,
                    };
                    clip.midi_notes.push(clip_note);
                    // Update content length if needed
                    let note_end = start_tick + duration_ticks;
                    if note_end > clip.content_length_ticks {
                        clip.content_length_ticks = note_end;
                    }
                    info!(
                        "Note {} added to clip {}: note={} start={} dur={}",
                        note_id, clip_id, note, start_tick, duration_ticks
                    );
                }
            } else {
                warn!("Clip not found for add note: {}", clip_id);
            }
        }
        AudioCommand::RemoveNoteFromClip { clip_id, note_id } => {
            if let Some(clip) = state.clips.get_mut(&clip_id) {
                let initial_len = clip.midi_notes.len();
                clip.midi_notes.retain(|n| n.id != note_id);
                if clip.midi_notes.len() != initial_len {
                    info!("Note {} removed from clip {}", note_id, clip_id);
                    // Recalculate content length
                    clip.content_length_ticks = clip
                        .midi_notes
                        .iter()
                        .map(|n| n.start_tick + n.duration_ticks)
                        .max()
                        .unwrap_or(0);
                } else {
                    warn!("Note {} not found in clip {}", note_id, clip_id);
                }
            } else {
                warn!("Clip not found for remove note: {}", clip_id);
            }
        }
        AudioCommand::UpdateClipNote {
            clip_id,
            note_id,
            note,
            start_tick,
            duration_ticks,
            velocity,
        } => {
            if let Some(clip) = state.clips.get_mut(&clip_id) {
                // Check for duplicate notes with same ID (shouldn't happen but let's be defensive)
                let matching_notes: Vec<_> =
                    clip.midi_notes.iter().filter(|n| n.id == note_id).collect();

                if matching_notes.len() > 1 {
                    warn!(
                        "Found {} duplicate notes with ID {} in clip {} - removing duplicates",
                        matching_notes.len(),
                        note_id,
                        clip_id
                    );
                    // Keep only the first one
                    let mut found_first = false;
                    clip.midi_notes.retain(|n| {
                        if n.id == note_id {
                            if found_first {
                                return false; // Remove duplicate
                            }
                            found_first = true;
                        }
                        true
                    });
                }

                if let Some(clip_note) = clip.midi_notes.iter_mut().find(|n| n.id == note_id) {
                    clip_note.note = note;
                    clip_note.start_tick = start_tick;
                    clip_note.duration_ticks = duration_ticks;
                    clip_note.velocity = velocity;
                    // Recalculate content length
                    clip.content_length_ticks = clip
                        .midi_notes
                        .iter()
                        .map(|n| n.start_tick + n.duration_ticks)
                        .max()
                        .unwrap_or(0);
                    info!(
                        "Note {} updated in clip {}: note={} start={} dur={}",
                        note_id, clip_id, note, start_tick, duration_ticks
                    );
                } else {
                    warn!("Note {} not found in clip {}", note_id, clip_id);
                }
            } else {
                warn!("Clip not found for update note: {}", clip_id);
            }
        }
        AudioCommand::BeginLoadAudioClip {
            clip_id,
            req_id,
            source_path,
        } => {
            if let Some(clip) = state.clips.get_mut(&clip_id) {
                info!(
                    "Begin loading audio clip {} from {} (req_id={})",
                    clip_id, source_path, req_id
                );

                clip.audio_source_path = Some(source_path.clone());
                clip.waveform_cache_key = None;
                clip.audio_samples.clear();
                clip.content_length_ticks = 0;
                clip.load_state = ClipLoadState::Loading {
                    req_id: req_id.clone(),
                };

                return Some(EngineStatus::ClipLoadStateChanged {
                    clip_id,
                    state: clip.load_state.clone(),
                    source_path: clip.audio_source_path.clone(),
                    cache_key: clip.waveform_cache_key.clone(),
                    sample_rate: None,
                    channels: None,
                });
            } else {
                warn!("Clip not found for begin load: {}", clip_id);
            }
        }
        AudioCommand::LoadAudioClip {
            clip_id,
            req_id,
            source_path,
            cache_key,
            samples,
            sample_rate,
            channels,
        } => {
            if let Some(clip) = state.clips.get_mut(&clip_id) {
                if let ClipLoadState::Loading {
                    req_id: current_req,
                } = &clip.load_state
                {
                    if current_req != &req_id {
                        warn!(
                            "Stale clip load event for {} (expected req_id {}, got {})",
                            clip_id, current_req, req_id
                        );
                        return None;
                    }
                }

                info!(
                    "Audio clip {} ready ({} samples, {} Hz, {} channels)",
                    clip_id,
                    samples.len(),
                    sample_rate,
                    channels
                );

                // Move rather than clone: decoded files can be hundreds of MB, and this runs
                // with the state lock held
                let total_samples = samples.len();
                clip.audio_samples = samples;
                clip.audio_sample_rate = sample_rate;
                clip.audio_channels = channels;
                clip.audio_source_path = Some(source_path.clone());
                clip.waveform_cache_key = cache_key.clone();
                clip.load_state = ClipLoadState::Ready {
                    req_id: req_id.clone(),
                };

                // Calculate content length in ticks
                if channels > 0 && sample_rate > 0 {
                    let sample_count = total_samples / channels;
                    let duration_seconds = sample_count as f32 / sample_rate as f32;
                    // Assuming 120 BPM = 2 beats per second, PPQ = 960 ticks per beat
                    let beats = duration_seconds * 2.0;
                    clip.content_length_ticks = (beats * 960.0) as i64;
                } else {
                    clip.content_length_ticks = 0;
                }

                return Some(EngineStatus::ClipLoadStateChanged {
                    clip_id,
                    state: clip.load_state.clone(),
                    source_path: clip.audio_source_path.clone(),
                    cache_key: clip.waveform_cache_key.clone(),
                    sample_rate: Some(sample_rate),
                    channels: Some(channels),
                });
            } else {
                warn!("Clip not found for load audio: {}", clip_id);
            }
        }
        AudioCommand::FailAudioClipLoad {
            clip_id,
            req_id,
            message,
        } => {
            if let Some(clip) = state.clips.get_mut(&clip_id) {
                warn!(
                    "Audio clip {} failed to load (req_id={}): {}",
                    clip_id, req_id, message
                );

                clip.audio_samples.clear();
                clip.content_length_ticks = 0;
                clip.waveform_cache_key = None;
                clip.load_state = ClipLoadState::Failed {
                    req_id: Some(req_id.clone()),
                    message: message.clone(),
                };

                return Some(EngineStatus::ClipLoadStateChanged {
                    clip_id,
                    state: clip.load_state.clone(),
                    source_path: clip.audio_source_path.clone(),
                    cache_key: clip.waveform_cache_key.clone(),
                    sample_rate: None,
                    channels: None,
                });
            } else {
                warn!(
                    "Clip not found for fail audio load: {} (req_id={}, msg={})",
                    clip_id, req_id, message
                );
            }
        }

        // ClipInstance management commands
        AudioCommand::CreateClipInstance {
            track_id,
            instance_id,
            clip_id,
            start_tick,
            duration_ticks,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                let instance = ClipInstance::new(
                    instance_id.clone(),
                    clip_id.clone(),
                    start_tick,
                    duration_ticks,
                );
                track.clip_instances.push(instance);
                info!(
                    "ClipInstance {} created on track {}: clip={} start={} dur={}",
                    instance_id, track_id, clip_id, start_tick, duration_ticks
                );
            } else {
                warn!("Track not found for create instance: {}", track_id);
            }
        }
        AudioCommand::RemoveClipInstance {
            track_id,
            instance_id,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                let initial_len = track.clip_instances.len();
                track.clip_instances.retain(|i| i.id != instance_id);
                if track.clip_instances.len() != initial_len {
                    info!(
                        "ClipInstance {} removed from track {}",
                        instance_id, track_id
                    );
                } else {
                    warn!(
                        "ClipInstance {} not found on track {}",
                        instance_id, track_id
                    );
                }
            } else {
                warn!("Track not found for remove instance: {}", track_id);
            }
        }
        AudioCommand::UpdateClipInstancePosition {
            track_id,
            instance_id,
            start_tick,
            duration_ticks,
            clip_offset,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                if let Some(instance) = track
                    .clip_instances
                    .iter_mut()
                    .find(|i| i.id == instance_id)
                {
                    instance.start_tick = start_tick;
                    instance.duration_ticks = duration_ticks;
                    instance.clip_offset = clip_offset;

                    // Reset playback position when clip_offset changes
                    // (will be re-initialized with new offset on next playback)
                    track.audio_playback_positions.remove(&instance_id);

                    info!(
                        "ClipInstance {} position updated: start={} dur={} offset={}",
                        instance_id, start_tick, duration_ticks, clip_offset
                    );
                } else {
                    warn!(
                        "ClipInstance {} not found on track {}",
                        instance_id, track_id
                    );
                }
            } else {
                warn!("Track not found for update instance position: {}", track_id);
            }
        }
        AudioCommand::UpdateClipInstanceTranspose {
            track_id,
            instance_id,
            transpose,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                if let Some(instance) = track
                    .clip_instances
                    .iter_mut()
                    .find(|i| i.id == instance_id)
                {
                    instance.transpose = transpose;
                    info!(
                        "ClipInstance {} transpose updated: {}",
                        instance_id, transpose
                    );
                } else {
                    warn!(
                        "ClipInstance {} not found on track {}",
                        instance_id, track_id
                    );
                }
            } else {
                warn!(
                    "Track not found for update instance transpose: {}",
                    track_id
                );
            }
        }
        AudioCommand::UpdateClipInstanceGain {
            track_id,
            instance_id,
            gain_db,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                if let Some(instance) = track
                    .clip_instances
                    .iter_mut()
                    .find(|i| i.id == instance_id)
                {
                    instance.gain_offset = gain_db;
                    info!("ClipInstance {} gain updated: {} dB", instance_id, gain_db);
                } else {
                    warn!(
                        "ClipInstance {} not found on track {}",
                        instance_id, track_id
                    );
                }
            } else {
                warn!("Track not found for update instance gain: {}", track_id);
            }
        }
        AudioCommand::UpdateClipInstanceMute {
            track_id,
            instance_id,
            muted,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                if let Some(instance) = track
                    .clip_instances
                    .iter_mut()
                    .find(|i| i.id == instance_id)
                {
                    instance.muted = muted;
                    info!("ClipInstance {} mute updated: {}", instance_id, muted);
                } else {
                    warn!(
                        "ClipInstance {} not found on track {}",
                        instance_id, track_id
                    );
                }
            } else {
                warn!("Track not found for update instance mute: {}", track_id);
            }
        }
        AudioCommand::UpdateClipInstanceLoop {
            track_id,
            instance_id,
            enabled,
            start_tick,
            length_ticks,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                if let Some(instance) = track
                    .clip_instances
                    .iter_mut()
                    .find(|i| i.id == instance_id)
                {
                    instance.loop_enabled = enabled;
                    instance.loop_start_ticks = start_tick;
                    instance.loop_length_ticks = length_ticks;
                    info!(
                        "ClipInstance {} loop updated: enabled={} start={} length={}",
                        instance_id, enabled, start_tick, length_ticks
                    );
                } else {
                    warn!(
                        "ClipInstance {} not found on track {}",
                        instance_id, track_id
                    );
                }
            } else {
                warn!("Track not found for update instance loop: {}", track_id);
            }
        }

        // Device management commands
        AudioCommand::MoveDevice {
            channel_id,
            parent_path,
            from_position,
            to_position,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                match super::devices::container::move_device(
                    &mut channel.devices,
                    &parent_path,
                    from_position,
                    to_position,
                ) {
                    Ok(()) => info!(
                        "Device moved in channel {} parent {} from {} to {}",
                        channel_id, parent_path, from_position, to_position
                    ),
                    Err(e) => warn!("{}", e),
                }
            } else {
                warn!("Channel {} not found for move device", channel_id);
            }
        }
        AudioCommand::SetDeviceParameter {
            channel_id,
            device_path,
            param_id,
            value,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                let Some(device) = channel.device_at_path_mut(&device_path) else {
                    warn!(
                        "Invalid device path {} for channel {}",
                        device_path, channel_id
                    );
                    return None;
                };
                let params = device.parameters();
                let mut normalized: f32 = 0.0;
                if let Some(info) = params.iter().find(|p| p.id == param_id) {
                    match value {
                        super::types::ParamSetValue::Normalized(v) => {
                            normalized = v.clamp(0.0, 1.0);
                        }
                        super::types::ParamSetValue::Index(idx) => match info.param_type {
                            super::devices::ParamType::Bool => {
                                normalized = if idx <= 0 { 0.0 } else { 1.0 };
                            }
                            super::devices::ParamType::Enum => {
                                let n = info.enum_values.len();
                                if n > 1 {
                                    let i = idx.max(0) as usize;
                                    let i = i.min(n - 1);
                                    normalized = (i as f32) / ((n - 1) as f32);
                                } else {
                                    normalized = 0.0;
                                }
                            }
                            super::devices::ParamType::Float => {
                                normalized = if idx <= 0 { 0.0 } else { 1.0 };
                            }
                        },
                    }
                } else if let super::types::ParamSetValue::Normalized(v) = value {
                    normalized = v.clamp(0.0, 1.0);
                }

                device.set_parameter(param_id, normalized);
                info!(
                    "Device parameter set: channel={} device={} param={} value={}",
                    channel_id, device_path, param_id, normalized
                );
                let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                    channel_id,
                    device_path,
                    param_id,
                    value: normalized,
                });
            } else {
                warn!("Channel {} not found for set device parameter", channel_id);
            }
        }
        AudioCommand::SetDeviceActive {
            channel_id,
            device_path,
            active,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if active && !device.is_active() {
                        match device.activate() {
                            Ok(_) => {
                                info!(
                                    "Device activated: channel={} device={}",
                                    channel_id, device_path
                                );
                                let _ = status_tx.send(EngineStatus::DeviceActiveChanged {
                                    channel_id,
                                    device_path,
                                    active: true,
                                });
                            }
                            Err(e) => {
                                warn!(
                                    "Failed to activate device at channel {} path {}: {}",
                                    channel_id, device_path, e
                                );
                            }
                        }
                    } else if !active && device.is_active() {
                        match device.deactivate() {
                            Ok(_) => {
                                info!(
                                    "Device deactivated: channel={} device={}",
                                    channel_id, device_path
                                );
                                let _ = status_tx.send(EngineStatus::DeviceActiveChanged {
                                    channel_id,
                                    device_path,
                                    active: false,
                                });
                            }
                            Err(e) => {
                                warn!(
                                    "Failed to deactivate device at channel {} path {}: {}",
                                    channel_id, device_path, e
                                );
                            }
                        }
                    }
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for set device active", channel_id);
            }
        }
        AudioCommand::SetDeviceEnabled {
            channel_id,
            device_path,
            enabled,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    device.set_enabled(enabled);
                    info!(
                        "Device set to {}: channel={} device={}",
                        if enabled { "enabled" } else { "bypassed" },
                        channel_id,
                        device_path
                    );
                    let _ = status_tx.send(EngineStatus::DeviceEnabledChanged {
                        channel_id,
                        device_path,
                        enabled,
                    });
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for set device enabled", channel_id);
            }
        }
        AudioCommand::LoadDeviceFile {
            channel_id,
            device_path,
            file_path,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(sfizz_device) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::SfizzDevice>()
                    {
                        info!(
                            "Loading SFZ file into device: channel={} device={} path={}",
                            channel_id, device_path, file_path
                        );
                        sfizz_device.load_sfz_async(std::path::PathBuf::from(file_path));
                    } else {
                        warn!(
                            "Device at channel {} path {} does not support file loading",
                            channel_id, device_path
                        );
                    }
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for load device file", channel_id);
            }
        }
        AudioCommand::BeginLoadDeviceSample {
            channel_id,
            device_path,
            req_id,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(sampler) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::SamplerDevice>()
                    {
                        sampler.begin_sample_load(req_id);
                    } else {
                        warn!(
                            "Device at channel {} path {} is not a Sampler",
                            channel_id, device_path
                        );
                    }
                }
            }
        }
        AudioCommand::LoadDeviceSample {
            channel_id,
            device_path,
            req_id,
            samples,
            sample_rate,
            channels,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(sampler) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::SamplerDevice>()
                    {
                        sampler.set_sample(&req_id, samples, channels, sample_rate);
                    } else {
                        warn!(
                            "Device at channel {} path {} is not a Sampler",
                            channel_id, device_path
                        );
                    }
                }
            }
        }
        AudioCommand::FailDeviceSampleLoad {
            channel_id,
            device_path,
            req_id,
            message,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(sampler) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::SamplerDevice>()
                    {
                        sampler.fail_sample_load(&req_id, &message);
                    }
                }
            }
        }
        AudioCommand::GetPluginParameters {
            channel_id,
            device_path,
        } => {
            if let Some(channel) = state.channels.get(&channel_id) {
                if let Some(device) = channel.device_at_path(&device_path) {
                    let params = device.parameters();
                    info!(
                        "Querying {} parameters for device at channel {} path {}",
                        params.len(),
                        channel_id,
                        device_path
                    );
                    let _ = status_tx.send(EngineStatus::PluginParameterCount {
                        channel_id,
                        device_path: device_path.clone(),
                        count: params.len(),
                    });
                    for param in params.iter() {
                        let _ = status_tx.send(EngineStatus::PluginParameterInfo {
                            channel_id,
                            device_path: device_path.clone(),
                            param_id: param.id,
                            name: param.name.clone(),
                            min: param.min,
                            max: param.max,
                            default: param.default,
                            group: device.parameter_group(param.id).to_string(),
                        });
                    }
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for get plugin parameters", channel_id);
            }
        }
        AudioCommand::DeviceReady {
            channel_id,
            device_path,
        } => {
            info!(
                "Device ready notification for channel {} path {}, re-sending parameters",
                channel_id, device_path
            );
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(subprocess_device) =
                        device
                            .as_any_mut()
                            .downcast_mut::<super::devices::clap_host::SubprocessClapAdapter>()
                    {
                        subprocess_device.on_device_ready();
                    }
                    let params = device.parameters();
                    if !params.is_empty() {
                        let _ = status_tx.send(EngineStatus::PluginParameterCount {
                            channel_id,
                            device_path: device_path.clone(),
                            count: params.len(),
                        });
                        for param in params.iter() {
                            let _ = status_tx.send(EngineStatus::PluginParameterInfo {
                                channel_id,
                                device_path: device_path.clone(),
                                param_id: param.id,
                                name: param.name.clone(),
                                min: param.min,
                                max: param.max,
                                default: param.default,
                                group: device.parameter_group(param.id).to_string(),
                            });
                        }
                    }
                }
            }
        }
        AudioCommand::SavePluginState {
            channel_id,
            device_path,
        } => {
            if let Some(channel) = state.channels.get(&channel_id) {
                if channel.device_at_path(&device_path).is_some() {
                    info!(
                        "Save plugin state requested for channel {} device {}",
                        channel_id, device_path
                    );
                    let _ = status_tx.send(EngineStatus::PluginStateSaved {
                        channel_id,
                        device_path,
                        state_base64: String::new(),
                    });
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for save plugin state", channel_id);
            }
        }
        AudioCommand::LoadPluginState {
            channel_id,
            device_path,
            state_base64,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if channel.device_at_path_mut(&device_path).is_some() {
                    info!(
                        "Load plugin state requested for channel {} device {} ({} bytes)",
                        channel_id,
                        device_path,
                        state_base64.len()
                    );
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for load plugin state", channel_id);
            }
        }
        AudioCommand::OpenPluginGui {
            channel_id,
            device_path,
            ..
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    use super::devices::clap_host::ClapDeviceAdapter;
                    if let Some(clap_device) =
                        (device.as_any_mut()).downcast_mut::<ClapDeviceAdapter>()
                    {
                        match clap_device.open_gui() {
                            Ok(()) => {
                                info!(
                                    "Opened GUI for in-process plugin at channel {} device {}",
                                    channel_id, device_path
                                );
                            }
                            Err(e) => {
                                warn!(
                                    "Failed to open in-process plugin GUI at channel {} device {}: {}",
                                    channel_id, device_path, e
                                );
                            }
                        }
                    } else {
                        warn!(
                            "Device at channel {} path {} is not a CLAP plugin",
                            channel_id, device_path
                        );
                    }
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for open plugin GUI", channel_id);
            }
        }
        AudioCommand::ClosePluginGui {
            channel_id,
            device_path,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    use super::devices::clap_host::ClapDeviceAdapter;
                    if let Some(clap_device) =
                        (device.as_any_mut()).downcast_mut::<ClapDeviceAdapter>()
                    {
                        match clap_device.close_gui() {
                            Ok(()) => {
                                info!(
                                    "Closed GUI for in-process plugin at channel {} device {}",
                                    channel_id, device_path
                                );
                                let _ = status_tx.send(EngineStatus::PluginGuiClosed {
                                    channel_id,
                                    device_path,
                                });
                            }
                            Err(e) => {
                                warn!(
                                    "Failed to close in-process plugin GUI at channel {} device {}: {}",
                                    channel_id, device_path, e
                                );
                            }
                        }
                    } else {
                        warn!(
                            "Device at channel {} path {} is not a CLAP plugin",
                            channel_id, device_path
                        );
                    }
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for close plugin GUI", channel_id);
            }
        }
        AudioCommand::SubscribeDeviceData {
            channel_id,
            device_path,
            data_type,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    match device.subscribe_data(&data_type) {
                        Ok(()) => {
                            info!(
                                "Subscribed to '{}' data on channel {} device {}",
                                data_type, channel_id, device_path
                            );
                        }
                        Err(e) => {
                            warn!(
                                "Failed to subscribe to '{}' on channel {} device {}: {}",
                                data_type, channel_id, device_path, e
                            );
                        }
                    }
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!("Channel {} not found for subscribe device data", channel_id);
            }
        }
        AudioCommand::UnsubscribeDeviceData {
            channel_id,
            device_path,
            data_type,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    device.unsubscribe_data(&data_type);
                    info!(
                        "Unsubscribed from '{}' data on channel {} device {}",
                        data_type, channel_id, device_path
                    );
                } else {
                    warn!(
                        "Device not found at channel {} path {}",
                        channel_id, device_path
                    );
                }
            } else {
                warn!(
                    "Channel {} not found for unsubscribe device data",
                    channel_id
                );
            }
        }
        AudioCommand::SetLayerSlotVolume {
            channel_id,
            device_path,
            slot,
            volume,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(layer) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::LayerDevice>()
                    {
                        if !layer.set_slot_volume_normalized(slot, volume) {
                            warn!(
                                "Layer slot {} not found at channel {} path {}",
                                slot, channel_id, device_path
                            );
                        }
                    } else {
                        warn!(
                            "Device at channel {} path {} is not a Layer",
                            channel_id, device_path
                        );
                    }
                }
            }
        }
        AudioCommand::SetLayerSlotMute {
            channel_id,
            device_path,
            slot,
            mute,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(layer) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::LayerDevice>()
                    {
                        if !layer.set_slot_mute(slot, mute) {
                            warn!(
                                "Layer slot {} not found at channel {} path {}",
                                slot, channel_id, device_path
                            );
                        }
                    }
                }
            }
        }
        AudioCommand::SetLayerSlotSolo {
            channel_id,
            device_path,
            slot,
            solo,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(layer) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::LayerDevice>()
                    {
                        if !layer.set_slot_solo(slot, solo) {
                            warn!(
                                "Layer slot {} not found at channel {} path {}",
                                slot, channel_id, device_path
                            );
                        }
                    }
                }
            }
        }
        AudioCommand::SetDrumSlotNote {
            channel_id,
            device_path,
            slot,
            note,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(drum) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::DrumMachineDevice>()
                    {
                        if !drum.set_slot_note(slot, note) {
                            warn!(
                                "Drum slot {} note {} rejected at channel {} path {}",
                                slot, note, channel_id, device_path
                            );
                        }
                    } else {
                        warn!(
                            "Device at channel {} path {} is not a Drum Machine",
                            channel_id, device_path
                        );
                    }
                }
            }
        }

        // Slow commands that must run with the state lock released
        other @ (AudioCommand::ClearProject
        | AudioCommand::RemoveChannel { .. }
        | AudioCommand::AddDeviceToChannel { .. }
        | AudioCommand::RemoveDeviceFromChannel { .. }
        | AudioCommand::ClearChannelDevices { .. }
        | AudioCommand::ScanPlugins
        | AudioCommand::AdvertiseBuiltinDevices) => {
            warn!("{:?} must be handled by CommandWorker, ignoring", other);
        }
    }

    None
}
