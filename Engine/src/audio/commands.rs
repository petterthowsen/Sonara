use crossbeam::channel::Sender;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use tracing::{info, warn};

use super::devices::AudioDevice;
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
    LoadAudioClip {
        clip_id: ClipId,
        samples: Vec<f32>,
        sample_rate: u32,
        channels: usize,
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
        device_id: String,
        device_type: String, // "builtin", "clap", "lv2", "vst3"
        device_file: String, // Path to plugin file (empty for built-ins)
        position: i32,
        active: bool,
        enabled: bool,
    },
    RemoveDeviceFromChannel {
        channel_id: ChannelId,
        position: usize,
    },
    ClearChannelDevices {
        channel_id: ChannelId,
    },
    SetDeviceParameter {
        channel_id: ChannelId,
        device_position: usize,
        param_id: u32,
        value: super::types::ParamSetValue,
    },
    SetDeviceActive {
        channel_id: ChannelId,
        device_position: usize,
        active: bool,
    },
    SetDeviceEnabled {
        channel_id: ChannelId,
        device_position: usize,
        enabled: bool,
    },
    LoadDeviceFile {
        channel_id: ChannelId,
        device_position: usize,
        file_path: String,
    },
    DeviceReady {
        channel_id: ChannelId,
        device_position: usize,
    },

    // Plugin management
    ScanPlugins,
    AdvertiseBuiltinDevices,
    GetPluginParameters {
        channel_id: ChannelId,
        device_position: usize,
    },
    SavePluginState {
        channel_id: ChannelId,
        device_position: usize,
    },
    LoadPluginState {
        channel_id: ChannelId,
        device_position: usize,
        state_base64: String,
    },

    // Plugin GUI
    OpenPluginGui {
        channel_id: ChannelId,
        device_position: usize,
        window_handle: Option<u64>,
    },
    ClosePluginGui {
        channel_id: ChannelId,
        device_position: usize,
    },

    // Device data subscriptions
    SubscribeDeviceData {
        channel_id: ChannelId,
        device_position: usize,
        data_type: String, // "spectrum", "oscilloscope", "phase", etc.
    },
    UnsubscribeDeviceData {
        channel_id: ChannelId,
        device_position: usize,
        data_type: String,
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
    /// Optional: sample-accurate transport position in samples
    SamplePositionUpdate(u64),
    PlayingStateChanged(bool),
    ChannelPeaks {
        id: ChannelId,
        peak_left: f32,
        peak_right: f32,
        rms_left: f32,
        rms_right: f32,
    },

    // Device state changes
    DeviceActiveChanged {
        channel_id: ChannelId,
        device_position: usize,
        active: bool,
    },
    DeviceEnabledChanged {
        channel_id: ChannelId,
        device_position: usize,
        enabled: bool,
    },
    DeviceReady {
        channel_id: ChannelId,
        device_position: usize,
    },
    DeviceLoadingStateChanged {
        channel_id: ChannelId,
        device_position: usize,
        state: String, // "idle", "loading", "ready", "failed:{error}"
    },

    // Plugin GUI events
    PluginGuiResizeRequest {
        channel_id: ChannelId,
        device_position: usize,
        width: u32,
        height: u32,
    },
    PluginGuiClosed {
        channel_id: ChannelId,
        device_position: usize,
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
        parameters: Vec<BuiltinParamInfo>,
    },
    BuiltinDevicesComplete {
        count: usize,
    },

    // Plugin parameter responses
    PluginParameterInfo {
        channel_id: ChannelId,
        device_position: usize,
        param_id: u32,
        name: String,
        min: f32,
        max: f32,
        default: f32,
    },
    PluginParameterCount {
        channel_id: ChannelId,
        device_position: usize,
        count: usize,
    },

    // Plugin state responses
    PluginStateSaved {
        channel_id: ChannelId,
        device_position: usize,
        state_base64: String,
    },

    // Plugin parameter value changes (from plugin GUI or internal modulation)
    PluginParameterValueChanged {
        channel_id: ChannelId,
        device_position: usize,
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
        device_position: usize,
        data_type: String,  // "spectrum", "oscilloscope", "phase", etc.
        data: Vec<u8>,      // Binary payload (device-specific format)
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
    pub plugin_scanner: super::devices::clap_host::PluginScanner, // CLAP plugin discovery
    pub process_manager: std::sync::Arc<super::ipc::ProcessManager>, // Subprocess manager for CLAP plugins
    pub is_playing: AtomicBool,
    pub current_tick: AtomicI64,
    /// Fractional tick accumulator carried across buffers for sample-accurate scheduling (stored as fixed-point * 1e9)
    pub fractional_tick_accumulator: AtomicI64,
    /// Master sample-accurate transport position (increments by frames per callback)
    pub current_sample_position: AtomicU64,
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
        self.fractional_tick_accumulator.store((value * 1_000_000_000.0) as i64, Ordering::Release);
    }

    /// Get the current sample position (lock-free)
    pub fn get_current_sample_position(&self) -> u64 {
        self.current_sample_position.load(Ordering::Acquire)
    }

    /// Advance the current sample position by the given number of samples (lock-free)
    pub fn advance_sample_position(&self, samples: u64) {
        self.current_sample_position
            .fetch_add(samples, Ordering::Release);
    }

    /// Get playing state (lock-free)
    pub fn get_is_playing(&self) -> bool {
        self.is_playing.load(Ordering::Acquire)
    }

    /// Set playing state (lock-free)
    pub fn set_is_playing(&self, playing: bool) {
        self.is_playing.store(playing, Ordering::Release);
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
        let process_manager = std::sync::Arc::new(super::ipc::ProcessManager::new());
        process_manager.start_monitoring();

        Self {
            settings: ProjectSettings::default(),
            device_sample_rate: 48000.0, // Default, will be overridden
            channels: HashMap::new(),
            tracks: HashMap::new(),
            clips: HashMap::new(),
            output_devices: Vec::new(),
            plugin_scanner: super::devices::clap_host::PluginScanner::new(),
            process_manager,
            is_playing: AtomicBool::new(false),
            current_tick: AtomicI64::new(0),
            fractional_tick_accumulator: AtomicI64::new(0),
            current_sample_position: AtomicU64::new(0),
        }
    }
}

/// Process a command (called from audio thread)
pub fn process_command(
    state: &mut EngineState,
    cmd: AudioCommand,
    buffer_size: usize,
    status_tx: &Sender<EngineStatus>,
    command_tx: &Sender<AudioCommand>,
) -> Option<EngineStatus> {
    match cmd {
        AudioCommand::InitProject(settings) => {
            state.settings = settings;
            info!(
                "Project initialized: {}bpm, {}/{}, PPQ={}, SR={}",
                state.settings.tempo,
                state.settings.time_numerator,
                state.settings.time_denominator,
                state.settings.ppq,
                state.device_sample_rate
            );
        }
        AudioCommand::ClearProject => {
            state.channels.clear();
            state.tracks.clear();
            state.clips.clear();
            state.set_current_tick(0);
            info!("Project cleared");
        }
        AudioCommand::Play => {
            state.set_is_playing(true);
            let position = state.settings.format_tick_position(state.get_current_tick());
            info!("Playback started at {}", position);
            return Some(EngineStatus::PlayingStateChanged(true));
        }
        AudioCommand::Pause => {
            state.set_is_playing(false);
            let position = state.settings.format_tick_position(state.get_current_tick());
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
            let position = state.settings.format_tick_position(state.get_current_tick());
            state.set_is_playing(false);
            state.set_current_tick(0);
            // Reset all channels and tracks
            for channel in state.channels.values_mut() {
                channel.active_voices.clear();
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
        AudioCommand::RemoveChannel { id } => {
            if let Some(_channel) = state.channels.remove(&id) {
                info!(
                    "Channel {} removed [total channels: {}]",
                    id,
                    state.channels.len()
                );
            } else {
                warn!("Cannot remove channel {}: not found", id);
            }
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
        AudioCommand::LoadAudioClip {
            clip_id,
            samples,
            sample_rate,
            channels,
        } => {
            if let Some(clip) = state.clips.get_mut(&clip_id) {
                info!(
                    "Storing audio clip: {} total values, {} channels (= {} frames)",
                    samples.len(),
                    channels,
                    samples.len() / channels
                );

                clip.audio_samples = samples.clone();
                clip.audio_sample_rate = sample_rate;
                clip.audio_channels = channels;

                // Calculate content length in ticks
                let sample_count = samples.len() / channels;
                let duration_seconds = sample_count as f32 / sample_rate as f32;
                // Assuming 120 BPM = 2 beats per second, PPQ = 960 ticks per beat
                let beats = duration_seconds * 2.0;
                clip.content_length_ticks = (beats * 960.0) as i64;

                info!(
                    "Audio clip {} loaded: {} samples, {} Hz, {} channels, {} ticks",
                    clip_id, sample_count, sample_rate, channels, clip.content_length_ticks
                );
            } else {
                warn!("Clip not found for load audio: {}", clip_id);
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
        AudioCommand::AddDeviceToChannel {
            channel_id,
            device_id,
            device_type,
            device_file,
            position,
            active,
            enabled,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                // Factory: create device by type
                let device: Option<Box<dyn super::devices::AudioDevice>> = match device_type
                    .as_str()
                {
                    // Built-in devices
                    "builtin" => match device_id.as_str() {
                        "sonara.builtin.oscillator" => {
                            info!(
                                "Loading built-in oscillator [active={}, enabled={}]",
                                active, enabled
                            );
                            Some(Box::new(super::devices::OscillatorDevice::new(
                                state.device_sample_rate,
                            )))
                        }
                        "sonara.builtin.polysynth" => {
                            info!(
                                "Loading built-in polysynth [active={}, enabled={}]",
                                active, enabled
                            );
                            Some(Box::new(super::devices::PolySynthDevice::new(
                                state.device_sample_rate,
                            )))
                        }
                        "sonara.builtin.delay" => {
                            info!(
                                "Loading built-in delay [active={}, enabled={}]",
                                active, enabled
                            );
                            Some(Box::new(super::devices::DelayDevice::new(
                                state.device_sample_rate,
                                5000.0,
                            )))
                        }
                        "sonara.builtin.sfizz" => {
                            info!(
                                "Loading built-in sfizz [active={}, enabled={}]",
                                active, enabled
                            );
                            Some(Box::new(super::devices::SfizzDevice::new(
                                state.device_sample_rate,
                                buffer_size,
                                channel_id as usize,
                                position as usize,
                                Some(status_tx.clone()),
                            )))
                        }
                        "sonara.builtin.spectrum_analyzer" => {
                            info!(
                                "Loading built-in spectrum analyzer [active={}, enabled={}]",
                                active, enabled
                            );
                            Some(Box::new(super::devices::SpectrumAnalyzerDevice::new(
                                state.device_sample_rate,
                            )))
                        }
                        _ => {
                            warn!("Unknown built-in device ID: {}", device_id);
                            None
                        }
                    },
                    // CLAP plugins
                    "clap" => {
                        if device_file.is_empty() {
                            warn!("CLAP plugin {} missing file path", device_id);
                            None
                        } else {
                            info!(
                                "Loading CLAP plugin {} from {} [active={}, enabled={}]",
                                device_id, device_file, active, enabled
                            );

                            // Use subprocess-based adapter for better crash isolation and GUI support
                            match super::devices::clap_host::SubprocessClapAdapter::new(
                                std::sync::Arc::clone(&state.process_manager),
                                channel_id as u32,
                                position as usize,
                                std::path::PathBuf::from(&device_file),
                                &device_id,
                                state.device_sample_rate,
                                buffer_size,
                                Some(command_tx.clone()),
                                Some(status_tx.clone()),
                            ) {
                                Ok(adapter) => {
                                    // Note: Don't activate on audio thread! It will be activated later.
                                    // Activation requires IPC which is too slow for real-time audio thread.
                                    info!("CLAP plugin {} loaded successfully in subprocess (activation deferred)", device_id);
                                    Some(Box::new(adapter))
                                }
                                Err(e) => {
                                    warn!("Failed to load CLAP plugin {}: {}", device_id, e);
                                    None
                                }
                            }
                        }
                    }
                    _ => {
                        warn!(
                            "Unknown device type: {} (supported: builtin, clap)",
                            device_type
                        );
                        None
                    }
                };

                if let Some(mut device) = device {
                    // Set enabled state for all devices
                    device.set_enabled(enabled);

                    let insert_pos = if position < 0 {
                        channel.devices.len() // Append to end
                    } else {
                        (position as usize).min(channel.devices.len()) // Insert at position or at end
                    };
                    channel.devices.insert(insert_pos, device);
                    info!(
                        "Device {} added to channel {} at position {} [active={}, enabled={}]",
                        device_id, channel_id, insert_pos, active, enabled
                    );
                }
            } else {
                warn!("Channel {} not found for add device", channel_id);
            }
        }
        AudioCommand::RemoveDeviceFromChannel {
            channel_id,
            position,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if position < channel.devices.len() {
                    channel.devices.remove(position);
                    info!(
                        "Device removed from channel {} at position {}",
                        channel_id, position
                    );
                } else {
                    warn!(
                        "Invalid device position {} for channel {}",
                        position, channel_id
                    );
                }
            } else {
                warn!("Channel {} not found for remove device", channel_id);
            }
        }
        AudioCommand::ClearChannelDevices { channel_id } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                channel.devices.clear();
                info!("All devices cleared from channel {}", channel_id);
            } else {
                warn!("Channel {} not found for clear devices", channel_id);
            }
        }
        AudioCommand::SetDeviceParameter {
            channel_id,
            device_position,
            param_id,
            value,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if device_position < channel.devices.len() {
                    // Determine normalized value based on ParamInfo
                    let device = &channel.devices[device_position];
                    let params = device.parameters();
                    let mut normalized: f32 = 0.0;
                    if let Some(info) = params.iter().find(|p| p.id == param_id) {
                        match value {
                            super::types::ParamSetValue::Normalized(v) => {
                                normalized = v.clamp(0.0, 1.0);
                            }
                            super::types::ParamSetValue::Index(idx) => {
                                match info.param_type {
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
                                        // Treat index as 0/1 for floats as a fallback
                                        normalized = if idx <= 0 { 0.0 } else { 1.0 };
                                    }
                                }
                            }
                        }
                    } else {
                        // Unknown param: use float if provided
                        if let super::types::ParamSetValue::Normalized(v) = value {
                            normalized = v.clamp(0.0, 1.0);
                        }
                    }

                    if channel.set_device_parameter(device_position, param_id, normalized) {
                        info!(
                            "Device parameter set: channel={} device={} param={} value={}",
                            channel_id, device_position, param_id, normalized
                        );
                        // Echo back to UI so Godot updates its single source of truth and emits parameter_changed
                        let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                            channel_id,
                            device_position,
                            param_id,
                            value: normalized,
                        });
                    } else {
                        warn!(
                            "Invalid device position {} for channel {}",
                            device_position, channel_id
                        );
                    }
                } else {
                    warn!(
                        "Invalid device position {} for channel {}",
                        device_position, channel_id
                    );
                }
            } else {
                warn!("Channel {} not found for set device parameter", channel_id);
            }
        }
        AudioCommand::SetDeviceActive {
            channel_id,
            device_position,
            active,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    if active && !device.is_active() {
                        // Activate
                        match device.activate() {
                            Ok(_) => {
                                info!(
                                    "Device activated: channel={} device={}",
                                    channel_id, device_position
                                );
                                // Send status update back to UI
                                let _ = status_tx.send(EngineStatus::DeviceActiveChanged {
                                    channel_id,
                                    device_position,
                                    active: true,
                                });
                            }
                            Err(e) => {
                                warn!(
                                    "Failed to activate device at channel {} position {}: {}",
                                    channel_id, device_position, e
                                );
                            }
                        }
                    } else if !active && device.is_active() {
                        // Deactivate
                        match device.deactivate() {
                            Ok(_) => {
                                info!(
                                    "Device deactivated: channel={} device={}",
                                    channel_id, device_position
                                );
                                // Send status update back to UI
                                let _ = status_tx.send(EngineStatus::DeviceActiveChanged {
                                    channel_id,
                                    device_position,
                                    active: false,
                                });
                            }
                            Err(e) => {
                                warn!(
                                    "Failed to deactivate device at channel {} position {}: {}",
                                    channel_id, device_position, e
                                );
                            }
                        }
                    }
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for set device active", channel_id);
            }
        }
        AudioCommand::SetDeviceEnabled {
            channel_id,
            device_position,
            enabled,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    device.set_enabled(enabled);
                    info!(
                        "Device {} set to {}: channel={} device={}",
                        if enabled { "enabled" } else { "disabled" },
                        if enabled { "enabled" } else { "bypassed" },
                        channel_id,
                        device_position
                    );
                    // Send status update back to UI
                    let _ = status_tx.send(EngineStatus::DeviceEnabledChanged {
                        channel_id,
                        device_position,
                        enabled,
                    });
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for set device enabled", channel_id);
            }
        }
        AudioCommand::LoadDeviceFile {
            channel_id,
            device_position,
            file_path,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    // Try to downcast to SfizzDevice
                    if let Some(sfizz_device) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::SfizzDevice>()
                    {
                        info!(
                            "Loading SFZ file into device: channel={} device={} path={}",
                            channel_id, device_position, file_path
                        );
                        sfizz_device.load_sfz_async(std::path::PathBuf::from(file_path));
                    } else {
                        warn!(
                            "Device at channel {} position {} does not support file loading",
                            channel_id, device_position
                        );
                    }
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for load device file", channel_id);
            }
        }

        // Plugin management commands
        AudioCommand::ScanPlugins => {
            info!("Starting plugin scan...");
            match state.plugin_scanner.scan() {
                Ok(count) => {
                    info!("Plugin scan complete: {} plugins found", count);

                    // Send info for each discovered plugin
                    for plugin in state.plugin_scanner.all_plugins() {
                        let category_str = match plugin.category {
                            super::devices::DeviceCategory::Instrument => "instrument",
                            super::devices::DeviceCategory::Effect => "effect",
                            super::devices::DeviceCategory::Utility => "utility",
                        }
                        .to_string();

                        let _ = status_tx.send(EngineStatus::PluginInfo {
                            id: plugin.id.clone(),
                            name: plugin.name.clone(),
                            vendor: plugin.vendor.clone(),
                            version: plugin.version.clone(),
                            category: category_str,
                            description: plugin.description.clone(),
                            path: plugin.path.to_string_lossy().to_string(),
                        });
                    }

                    // Send completion message last
                    return Some(EngineStatus::PluginScanComplete { count });
                }
                Err(e) => {
                    warn!("Plugin scan failed: {}", e);
                }
            }
        }

        AudioCommand::AdvertiseBuiltinDevices => {
            info!("Advertising builtin devices...");

            // Helper to create device info from a temporary device instance
            let create_device_info =
                |device: Box<dyn super::devices::AudioDevice>| -> EngineStatus {
                    let category_str = match device.device_category() {
                        super::devices::DeviceCategory::Instrument => "instrument",
                        super::devices::DeviceCategory::Effect => "effect",
                        super::devices::DeviceCategory::Utility => "utility",
                    }
                    .to_string();

                    let parameters: Vec<BuiltinParamInfo> = device
                        .parameters()
                        .into_iter()
                        .map(|p| BuiltinParamInfo {
                            id: p.id,
                            name: p.name,
                            unit: p.unit,
                            min: p.min,
                            max: p.max,
                            default: p.default,
                            param_type: p.param_type,
                            syncable: p.syncable,
                            enum_values: p.enum_values,
                        })
                        .collect();

                    let midi_ports = device.midi_ports();
                    let audio_ports = device.audio_ports();

                    let audio_in = audio_ports
                        .iter()
                        .find(|p| matches!(p.flow, super::devices::PortFlow::Input))
                        .map(|p| p.channels)
                        .unwrap_or(0);
                    let audio_out = audio_ports
                        .iter()
                        .find(|p| matches!(p.flow, super::devices::PortFlow::Output))
                        .map(|p| p.channels)
                        .unwrap_or(0);

                    let (supports_file_loading, file_extensions, file_type_description) =
                        match device.file_loading_support() {
                            Some(info) => (true, info.extensions, info.description),
                            None => (false, Vec::new(), String::new()),
                        };

                    EngineStatus::BuiltinDeviceInfo {
                        id: device.device_id().to_string(),
                        name: device.device_name().to_string(),
                        category: category_str,
                        description: format!("{} v{}", device.device_name(), device.version()),
                        accepts_midi: !midi_ports.is_empty(),
                        audio_in_channels: audio_in,
                        audio_out_channels: audio_out,
                        supports_file_loading,
                        file_extensions,
                        file_type_description,
                        parameters,
                    }
                };

            // Create temp instances of each builtin device and send their info
            let builtin_devices: Vec<EngineStatus> = vec![
                create_device_info(Box::new(super::devices::PolySynthDevice::new(
                    state.device_sample_rate,
                ))),
                create_device_info(Box::new(super::devices::DelayDevice::new(
                    state.device_sample_rate,
                    5000.0,
                ))),
                create_device_info(Box::new(super::devices::SpectrumAnalyzerDevice::new(
                    state.device_sample_rate,
                ))),
            ];

            let count = builtin_devices.len();
            for device_info in builtin_devices {
                let _ = status_tx.send(device_info);
            }

            info!("Advertised {} builtin devices", count);
            return Some(EngineStatus::BuiltinDevicesComplete { count });
        }

        AudioCommand::GetPluginParameters {
            channel_id,
            device_position,
        } => {
            if let Some(channel) = state.channels.get(&channel_id) {
                if let Some(device) = channel.devices.get(device_position) {
                    let params = device.parameters();
                    info!(
                        "Querying {} parameters for device at channel {} position {}",
                        params.len(),
                        channel_id,
                        device_position
                    );

                    // Send parameter count
                    let _ = status_tx.send(EngineStatus::PluginParameterCount {
                        channel_id,
                        device_position,
                        count: params.len(),
                    });

                    // Send parameter info for each parameter
                    for (idx, param) in params.iter().enumerate() {
                        let _ = status_tx.send(EngineStatus::PluginParameterInfo {
                            channel_id,
                            device_position,
                            param_id: idx as u32,
                            name: param.name.clone(),
                            min: param.min,
                            max: param.max,
                            default: param.default,
                        });
                    }
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for get plugin parameters", channel_id);
            }
        }

        AudioCommand::DeviceReady {
            channel_id,
            device_position,
        } => {
            info!(
                "Device ready notification for channel {} position {}, re-sending parameters",
                channel_id, device_position
            );

            // Re-send parameter info now that device is ready
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    if let Some(subprocess_device) =
                        device
                            .as_any_mut()
                            .downcast_mut::<super::devices::clap_host::SubprocessClapAdapter>()
                    {
                        subprocess_device.on_device_ready();
                    }

                    let params = device.parameters();

                    if !params.is_empty() {
                        // Send parameter count
                        let _ = status_tx.send(EngineStatus::PluginParameterCount {
                            channel_id,
                            device_position,
                            count: params.len(),
                        });

                        // Send parameter info for each parameter
                        for (idx, param) in params.iter().enumerate() {
                            let _ = status_tx.send(EngineStatus::PluginParameterInfo {
                                channel_id,
                                device_position,
                                param_id: idx as u32,
                                name: param.name.clone(),
                                min: param.min,
                                max: param.max,
                                default: param.default,
                            });
                        }
                    }
                }
            }
        }

        AudioCommand::SavePluginState {
            channel_id,
            device_position,
        } => {
            if let Some(channel) = state.channels.get(&channel_id) {
                if let Some(_device) = channel.devices.get(device_position) {
                    // Try to get state from device (if it's a CLAP plugin)
                    // For now, return empty state - will implement state extension later
                    info!(
                        "Save plugin state requested for channel {} device {}",
                        channel_id, device_position
                    );
                    let _ = status_tx.send(EngineStatus::PluginStateSaved {
                        channel_id,
                        device_position,
                        state_base64: String::new(), // TODO: Implement state save
                    });
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for save plugin state", channel_id);
            }
        }

        AudioCommand::LoadPluginState {
            channel_id,
            device_position,
            state_base64,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(_device) = channel.devices.get_mut(device_position) {
                    // TODO: Implement state load via CLAP state extension
                    info!(
                        "Load plugin state requested for channel {} device {} ({} bytes)",
                        channel_id,
                        device_position,
                        state_base64.len()
                    );
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for load plugin state", channel_id);
            }
        }

        // Plugin GUI commands (must be called on main thread when instance is available)
        AudioCommand::OpenPluginGui {
            channel_id,
            device_position,
            window_handle,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    // Try subprocess adapter first (preferred)
                    use super::devices::clap_host::{ClapDeviceAdapter, SubprocessClapAdapter};
                    if let Some(subprocess_device) =
                        (device.as_any_mut()).downcast_mut::<SubprocessClapAdapter>()
                    {
                        match subprocess_device.open_gui_with_handle(window_handle) {
                            Ok((width, height, _is_resizable)) => {
                                info!("Opened GUI for subprocess plugin at channel {} device {} (window_handle: {:?}, size: {}x{})",
                                    channel_id, device_position, window_handle, width, height);

                                // Send resize request so OSC server can resize the window
                                let _ = status_tx.send(EngineStatus::PluginGuiResizeRequest {
                                    channel_id,
                                    device_position,
                                    width,
                                    height,
                                });
                            }
                            Err(e) => {
                                warn!("Failed to open subprocess plugin GUI at channel {} device {}: {}",
                                    channel_id, device_position, e);
                            }
                        }
                    } else if let Some(clap_device) =
                        (device.as_any_mut()).downcast_mut::<ClapDeviceAdapter>()
                    {
                        match clap_device.open_gui() {
                            Ok(()) => {
                                info!(
                                    "Opened GUI for in-process plugin at channel {} device {}",
                                    channel_id, device_position
                                );
                            }
                            Err(e) => {
                                warn!("Failed to open in-process plugin GUI at channel {} device {}: {}",
                                    channel_id, device_position, e);
                            }
                        }
                    } else {
                        warn!(
                            "Device at channel {} position {} is not a CLAP plugin",
                            channel_id, device_position
                        );
                    }
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for open plugin GUI", channel_id);
            }
        }

        AudioCommand::ClosePluginGui {
            channel_id,
            device_position,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    // Try subprocess adapter first (preferred)
                    use super::devices::clap_host::{ClapDeviceAdapter, SubprocessClapAdapter};
                    if let Some(subprocess_device) =
                        (device.as_any_mut()).downcast_mut::<SubprocessClapAdapter>()
                    {
                        match subprocess_device.close_gui() {
                            Ok(()) => {
                                info!(
                                    "Closed GUI for subprocess plugin at channel {} device {}",
                                    channel_id, device_position
                                );
                                // Notify OSC that plugin GUI is closed so it can destroy the window
                                let _ = status_tx.send(EngineStatus::PluginGuiClosed {
                                    channel_id,
                                    device_position,
                                });
                            }
                            Err(e) => {
                                warn!("Failed to close subprocess plugin GUI at channel {} device {}: {}", 
                                    channel_id, device_position, e);
                            }
                        }
                    } else if let Some(clap_device) =
                        (device.as_any_mut()).downcast_mut::<ClapDeviceAdapter>()
                    {
                        match clap_device.close_gui() {
                            Ok(()) => {
                                info!(
                                    "Closed GUI for in-process plugin at channel {} device {}",
                                    channel_id, device_position
                                );
                                // Notify OSC that plugin GUI is closed so it can destroy the window
                                let _ = status_tx.send(EngineStatus::PluginGuiClosed {
                                    channel_id,
                                    device_position,
                                });
                            }
                            Err(e) => {
                                warn!("Failed to close in-process plugin GUI at channel {} device {}: {}", 
                                    channel_id, device_position, e);
                            }
                        }
                    } else {
                        warn!(
                            "Device at channel {} position {} is not a CLAP plugin",
                            channel_id, device_position
                        );
                    }
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for close plugin GUI", channel_id);
            }
        }

        AudioCommand::SubscribeDeviceData {
            channel_id,
            device_position,
            data_type,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    match device.subscribe_data(&data_type) {
                        Ok(()) => {
                            info!(
                                "Subscribed to '{}' data on channel {} device {}",
                                data_type, channel_id, device_position
                            );
                        }
                        Err(e) => {
                            warn!(
                                "Failed to subscribe to '{}' on channel {} device {}: {}",
                                data_type, channel_id, device_position, e
                            );
                        }
                    }
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!("Channel {} not found for subscribe device data", channel_id);
            }
        }

        AudioCommand::UnsubscribeDeviceData {
            channel_id,
            device_position,
            data_type,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.devices.get_mut(device_position) {
                    device.unsubscribe_data(&data_type);
                    info!(
                        "Unsubscribed from '{}' data on channel {} device {}",
                        data_type, channel_id, device_position
                    );
                } else {
                    warn!(
                        "Device not found at channel {} position {}",
                        channel_id, device_position
                    );
                }
            } else {
                warn!(
                    "Channel {} not found for unsubscribe device data",
                    channel_id
                );
            }
        }
    }

    None
}
