use crossbeam::channel::Sender;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tracing::{info, warn};

use super::automation::{
    AutomationLane, AutomationLaneId, AutomationPoint, AutomationPointId, AutomationTarget,
};
use super::block_clock::BlockClock;
use super::devices::sampler_zones::{GroupPlayMode, ZoneSettings};
use super::devices::DevicePath;
use super::midi_types::{NoteEvent, AUDITION_NOTE_ID};
use super::render_scratch::RenderScratch;
use super::tempo_map::TempoMap;
use super::time_signature_map::TimeSignatureMap;
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
    pub is_logarithmic: bool,
    pub skew: f32,
    /// Module the parameter belongs to (`Band 1`); "" if none. Disambiguates repeated names.
    pub module: String,
    /// False when driving it from the audio thread is unsafe (or it is a UI-only control).
    pub is_automation_safe: bool,
    /// Can a modulator drive this parameter?
    pub is_modulatable: bool,
}

impl From<&super::devices::ParamInfo> for BuiltinParamInfo {
    fn from(p: &super::devices::ParamInfo) -> Self {
        Self {
            id: p.id,
            name: p.name.clone(),
            unit: p.unit.clone(),
            min: p.min,
            max: p.max,
            default: p.default,
            param_type: p.param_type,
            syncable: p.syncable,
            enum_values: p.enum_values.clone(),
            is_logarithmic: p.is_logarithmic,
            skew: p.skew,
            module: p.module.clone(),
            is_automation_safe: p.is_automation_safe,
            is_modulatable: p.is_modulatable,
        }
    }
}

/// What `/audio/config` reports: the running stream, what was asked for, and the PipeWire graph.
#[derive(Debug, Clone, Default)]
pub struct AudioConfigReport {
    /// None while no stream could be opened.
    pub active: Option<super::stream::StreamInfo>,
    pub requested: super::stream::StreamRequest,
    /// The PipeWire graph quantum and rate (0 when unknown or not on PipeWire).
    pub graph_quantum: u32,
    pub graph_rate: u32,
    /// Graph/stream conflict for Settings, "" when none.
    pub mismatch: String,
    /// Why the running config differs from the request (device missing, rate unsupported), "".
    pub notice: String,
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
    /// Loop playback over `[start, end)` ticks. Disabled or `end <= start` means no loop.
    SetLoop {
        enabled: bool,
        start: Tick,
        end: Tick,
    },
    /// Render a range offline (export, stems). Live output is silent until it finishes.
    StartRender(super::render::RenderJob),
    /// Cancel the running render with this job id. It ends with `RenderFailed("cancelled")`.
    CancelRender {
        job_id: String,
    },
    SetTempo(f32),
    /// Whole tempo map as `(tick, bpm)` points; empty clears it.
    SetTempoMap(Vec<(Tick, f32)>),
    /// `(bar, numerator, denominator)` changes, 1-based bars. Replaces the whole map.
    SetTimeSignatureMap(Vec<(u32, u16, u16)>),
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
    SetChannelPanWidth {
        id: ChannelId,
        width: f32,
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

    // Automation (see `audio::automation`). None of these echo an `EngineStatus`: Godot owns the
    // lane data, and an echo would clobber and then persist the user's base values.
    CreateAutomationLane {
        track_id: TrackId,
        lane_id: AutomationLaneId,
        target: AutomationTarget,
    },
    DeleteAutomationLane {
        track_id: TrackId,
        lane_id: AutomationLaneId,
    },
    SetAutomationLaneBypass {
        track_id: TrackId,
        lane_id: AutomationLaneId,
        bypassed: bool,
    },
    AddAutomationPoint {
        track_id: TrackId,
        lane_id: AutomationLaneId,
        point: AutomationPoint,
    },
    UpdateAutomationPoint {
        track_id: TrackId,
        lane_id: AutomationLaneId,
        point: AutomationPoint,
    },
    RemoveAutomationPoint {
        track_id: TrackId,
        lane_id: AutomationLaneId,
        point_id: AutomationPointId,
    },
    ClearAutomationLane {
        track_id: TrackId,
        lane_id: AutomationLaneId,
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
        velocity: f32,
        release: f32,
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
        velocity: f32,
        release: f32,
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
    UpdateClipInstanceReverse {
        track_id: TrackId,
        instance_id: ClipInstanceId,
        reverse: bool,
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
    /// Add a modulator to a device, wrapping it if it isn't yet. Echoed as `ModulatorAdded`.
    AddModulator {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
        kind: String,
    },
    /// Remove a modulator and its routes. Echoed as `ModulatorRemoved`.
    RemoveModulator {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
    },
    /// Set a modulator parameter. Echoed as `ModulatorParamChanged`.
    SetModulatorParameter {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
        param_id: u32,
        value: f32,
    },
    /// Add, update or (amount 0) remove one modulator route. Echoed as `ModulatorRouteChanged`.
    SetModulatorRoute {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
        target: String,
        amount: f32,
    },
    /// Remove every modulator and route. Echoed as `ModulatorsCleared`.
    ClearModulators {
        channel_id: ChannelId,
        device_path: DevicePath,
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
    /// `zone_id` targets a Sampler multisample zone instead of its single sample.
    BeginLoadDeviceSample {
        channel_id: ChannelId,
        device_path: DevicePath,
        zone_id: Option<u32>,
        req_id: String,
    },
    LoadDeviceSample {
        channel_id: ChannelId,
        device_path: DevicePath,
        zone_id: Option<u32>,
        req_id: String,
        samples: Vec<f32>,
        sample_rate: u32,
        channels: usize,
    },
    FailDeviceSampleLoad {
        channel_id: ChannelId,
        device_path: DevicePath,
        zone_id: Option<u32>,
        req_id: String,
        message: String,
    },
    /// Switch a Sampler between single-sample and multisample mode (spec 023).
    SetSamplerMode {
        channel_id: ChannelId,
        device_path: DevicePath,
        multisample: bool,
    },
    /// Create or replace a Sampler zone's settings.
    SetSamplerZone {
        channel_id: ChannelId,
        device_path: DevicePath,
        zone_id: u32,
        settings: ZoneSettings,
    },
    RemoveSamplerZone {
        channel_id: ChannelId,
        device_path: DevicePath,
        zone_id: u32,
    },
    /// Create or replace a Sampler zone group (`group_id` 0 = Ungrouped).
    SetSamplerZoneGroup {
        channel_id: ChannelId,
        device_path: DevicePath,
        group_id: u32,
        gain: f32,
        mute: bool,
        solo: bool,
        play_mode: GroupPlayMode,
    },
    RemoveSamplerZoneGroup {
        channel_id: ChannelId,
        device_path: DevicePath,
        group_id: u32,
    },
    /// Which zone's voices the Sampler's `"playheads"` stream reports.
    SetSamplerFocus {
        channel_id: ChannelId,
        device_path: DevicePath,
        zone_id: u32,
    },
    /// Play a note into one device directly (the Sampler zone map's piano).
    AuditionDevice {
        channel_id: ChannelId,
        device_path: DevicePath,
        note: u8,
        velocity: u8,
        is_note_on: bool,
    },
    DeviceReady {
        channel_id: ChannelId,
        device_path: DevicePath,
        /// Parameter values read back from the plugin after a reload restored its state
        /// (Phase 4). Cached and reported to Godot after the parameter list is re-advertised,
        /// because Godot resets values to defaults when the list arrives. Empty on a first load.
        restored_values: Vec<(u32, f32)>,
    },

    // Plugin management
    ScanPlugins {
        paths: Vec<PathBuf>,
    },
    AdvertiseBuiltinDevices,
    GetPluginParameters {
        channel_id: ChannelId,
        device_path: DevicePath,
    },
    /// Re-send a device's loading state and (dynamic) parameter list, for a Godot that missed them.
    GetDeviceState {
        channel_id: ChannelId,
        device_path: DevicePath,
    },
    /// Write a plugin's state blob to `file_path` (project save). Replies `PluginStateSaved`.
    SavePluginState {
        channel_id: ChannelId,
        device_path: DevicePath,
        file_path: String,
    },
    /// Restore a plugin's state blob from `file_path` (project load).
    LoadPluginState {
        channel_id: ChannelId,
        device_path: DevicePath,
        file_path: String,
    },
    /// Respawn a crashed (or hung) plugin host and restore the plugin's state. Phase 4.
    ReloadDevice {
        channel_id: ChannelId,
        device_path: DevicePath,
    },
    /// How plugins are grouped into host processes: the global mode plus per-plugin overrides
    /// (plugin id → mode). Loaded plugins whose host changes are moved live. Phase 5.
    SetPluginHosting {
        policy: crate::audio::ipc::HostingPolicy,
    },

    // Audio device settings (Phase 7)
    /// Reopen the output stream on `device` ("" = system default) at `sample_rate` with
    /// `period_frames` per callback. Devices are prepared for a new rate while it is stopped.
    SetAudioConfig {
        device: String,
        sample_rate: u32,
        period_frames: u32,
    },
    /// Report the running config (`EngineStatus::AudioConfig`).
    RequestAudioConfig,
    /// List output devices (`AudioDeviceInfo` statuses, then `AudioDevicesComplete`).
    RequestAudioDevices,
    /// The PipeWire graph changed (from the monitor thread).
    PipeWireGraph(super::pipewire::GraphInfo),

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

    /// Show or hide an open plugin GUI (CLAP `gui.show()`/`gui.hide()`)
    SetPluginGuiVisible {
        channel_id: ChannelId,
        device_path: DevicePath,
        visible: bool,
    },

    /// Ask a resizable plugin GUI to take this size. Answered with `PluginGuiResizeRequest`
    /// carrying the size the plugin settled on.
    SetPluginGuiSize {
        channel_id: ChannelId,
        device_path: DevicePath,
        width: u32,
        height: u32,
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
    /// Set an option of a device data stream (`AudioDevice::configure_data`). Handled by
    /// `CommandWorker`, which builds new buffers with the state lock released.
    ConfigureDeviceData {
        channel_id: ChannelId,
        device_path: DevicePath,
        data_type: String,
        key: String,
        value: f32,
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
    /// Set a Drum Machine slot's choke targets as a note mask (bit k = the slot on note k). A
    /// note-on on this slot chokes every other slot whose note bit is set.
    SetDrumSlotChokeTargets {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        mask: u128,
    },
    /// Replace a Layer slot's note map (byte n = output note for input n, 255 = unmapped).
    SetLayerSlotNoteMap {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        map: Box<[u8; 128]>,
    },
    /// Route a Layer slot's audio to its extra bus (return channel) instead of the main mix.
    SetLayerSlotSeparateOut {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        separate: bool,
    },
    /// Play a note on one Layer slot directly, bypassing its note map (mapping window).
    AuditionLayerSlot {
        channel_id: ChannelId,
        device_path: DevicePath,
        slot: usize,
        note: u8,
        velocity: u8,
        is_note_on: bool,
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
    /// An offline render's progress, 0.0–1.0 (estimated while the tail renders until silent).
    RenderProgress {
        job_id: String,
        fraction: f32,
    },
    /// An offline render finished: the files it wrote (master first, then stems).
    RenderDone {
        job_id: String,
        outputs: Vec<PathBuf>,
    },
    /// An offline render failed or was cancelled (`error` is "cancelled"); nothing was written.
    RenderFailed {
        job_id: String,
        error: String,
    },
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
        state: String, // "idle", "loading", "ready", "failed:{error}", "crashed:{reason}"
    },
    /// A Sampler multisample zone's load state: "idle", "loading", "ready" or "failed:{error}".
    SamplerZoneLoadingState {
        channel_id: ChannelId,
        device_path: DevicePath,
        zone_id: u32,
        state: String,
    },
    /// A plugin host process died or stopped responding. `reason` is one line (signal or exit
    /// code), `stderr` is the tail of what the host printed, `pid` is the host's process id.
    /// Sent once per host, so several devices in one host each get it.
    DeviceCrashed {
        channel_id: ChannelId,
        device_path: DevicePath,
        reason: String,
        stderr: String,
        pid: u32,
        /// The host's log file ("" when unknown).
        log_path: String,
    },
    /// One second of a subprocess plugin's processing (Phase 6): its `process()` time as a share
    /// of real time (average and worst block), the same in microseconds, the blocks it was
    /// given and how many missed the callback deadline. `struggling` when it missed
    /// `MISSES_BEFORE_WARNING` or more in a row. `total_misses` counts since the device loaded.
    PluginStats {
        channel_id: ChannelId,
        device_path: DevicePath,
        load_avg: f32,
        load_peak: f32,
        process_avg_us: f32,
        process_max_us: f32,
        blocks: u64,
        deadline_misses: u64,
        total_misses: u64,
        struggling: bool,
    },
    /// A plugin finished loading into a host process: the hosting mode that chose the host, its
    /// key and its pid. Sent on every load, reload and move. Phase 5.
    PluginHost {
        channel_id: ChannelId,
        device_path: DevicePath,
        mode: String,
        host_key: String,
        pid: u32,
    },

    // Plugin GUI events
    /// A plugin GUI is open (sent after every successful open, also of an already-open GUI).
    /// `floating`: it runs in its own window instead of the host window it was given.
    PluginGuiOpened {
        channel_id: ChannelId,
        device_path: DevicePath,
        width: u32,
        height: u32,
        resizable: bool,
        floating: bool,
    },
    /// The GUI's size: the plugin resized itself, or settled on a size after `SetPluginGuiSize`
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
        features: Vec<String>,
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
        /// Modulators a fresh instance starts with (the device's default patch; empty: none).
        default_modulators: Vec<super::devices::DefaultModulator>,
    },
    BuiltinDevicesComplete {
        count: usize,
    },

    // Audio device settings (Phase 7)
    /// One output device, in answer to `RequestAudioDevices`.
    AudioDeviceInfo(super::stream::OutputDeviceInfo),
    AudioDevicesComplete {
        count: usize,
    },
    /// The running output config, after every change and on request.
    AudioConfig(AudioConfigReport),
    /// The device sample rate changed: clips decoded at the old rate should be reloaded.
    AudioConfigChanged {
        sample_rate: u32,
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
        param_type: super::devices::ParamType,
        is_hidden: bool,
        is_read_only: bool,
        is_bypass: bool,
        /// Can a modulator drive this parameter?
        is_modulatable: bool,
        /// CLAP module path, e.g. "Early/Size"; "" if none
        module: String,
        enum_values: Vec<String>,
        /// Unit of the display values ("Hz", "dB", …); "" if none
        unit: String,
        /// See `ParamInfo::display`
        display: Vec<f32>,
    },
    PluginParameterCount {
        channel_id: ChannelId,
        device_path: DevicePath,
        count: usize,
    },
    /// Key labels and keyswitches an SFZ declares, sent after every SFZ load (empty when it
    /// declares none, so Godot clears the previous file's labels). Each entry is
    /// `(key, is_keyswitch, label)`. `ranges` are the inclusive `(lo, hi)` keys the SFZ's
    /// regions play, sorted and merged.
    SfzKeyInfo {
        channel_id: ChannelId,
        device_path: DevicePath,
        keys: Vec<(u8, bool, String)>,
        ranges: Vec<(u8, u8)>,
    },

    // Plugin state responses
    /// `size` is the byte count written to `file_path`: 0 when the device has no state to
    /// save (not a plugin, or no state extension), -1 when saving failed.
    PluginStateSaved {
        channel_id: ChannelId,
        device_path: DevicePath,
        file_path: String,
        size: i64,
    },

    // Plugin parameter value changes (from plugin GUI or internal modulation)
    PluginParameterValueChanged {
        channel_id: ChannelId,
        device_path: DevicePath,
        param_id: u32,
        value: f32, // Normalized 0.0-1.0
    },

    /// A modulator was added (echo of `modulator/add`, or a `state/get` resend).
    ModulatorAdded {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
        kind: String,
    },
    /// A modulator was removed (echo of `modulator/{id}/remove`).
    ModulatorRemoved {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
    },
    /// A modulator parameter changed (echo of `modulator/{id}/param/{p}/value`, or a resend).
    ModulatorParamChanged {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
        param_id: u32,
        value: f32,
    },
    /// A modulator route was set (echo of `modulator/{id}/route/set`, or a resend).
    /// Amount 0 = removed.
    ModulatorRouteChanged {
        channel_id: ChannelId,
        device_path: DevicePath,
        mod_id: u8,
        target: String,
        amount: f32,
    },
    /// Every modulator was removed (echo of `modulator/clear`).
    ModulatorsCleared {
        channel_id: ChannelId,
        device_path: DevicePath,
    },
    /// The modulator kinds the engine offers follow (`/builtin/modulator_info`, then one
    /// `/builtin/modulator_kind` per kind, then `/builtin/modulator_complete`).
    ModulatorKindsInfo {
        count: usize,
    },
    /// One modulator kind: its stable id, display name, polarity and parameter table.
    ModulatorKindInfo {
        id: String,
        name: String,
        bipolar: bool,
        params: Vec<BuiltinParamInfo>,
    },
    ModulatorKindsComplete {
        count: usize,
    },

    // Log messages forwarded to Godot UI
    LogMessage {
        level: String, // "warn" or "error"
        message: String,
    },

    // Performance metrics, sent at 2 Hz from the audio callback.
    EngineStats {
        load_avg: f32,         // Processing time / block time over the interval (1.0 = 100%)
        load_peak: f32,        // Worst single block in the interval, same unit
        xruns: u64,            // Total since start: stream errors + callback gaps > 1.5x block time
        lock_misses: u64,      // Total since start: callbacks that output silence (state lock busy)
        callbacks: u64,        // Total since start
        frames: u32,           // Frames in the last block
        plugin_underruns: u64, // Total since start: plugin blocks padded with silence
        frames_min: u32,       // Smallest block in the interval
        frames_max: u32,       // Largest block in the interval
        peak_frames: u32,      // Frames in the block that set `load_peak`
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
    /// Rate of the running output stream. Changed only by the command thread while the stream
    /// is stopped (Phase 7).
    pub device_sample_rate: f32,
    pub channels: HashMap<ChannelId, Channel>,
    pub tracks: HashMap<TrackId, Track>,
    pub clips: HashMap<ClipId, Clip>, // Global clip pool
    /// Preallocated scratch lists so the audio callback doesn't allocate
    pub render_scratch: RenderScratch,
    /// Tempo automation; empty means the static `settings.tempo` applies.
    pub tempo_map: TempoMap,
    pub time_signature_map: TimeSignatureMap,
    pub is_playing: AtomicBool,
    pub current_tick: AtomicI64,
    /// Fractional tick accumulator carried across buffers for sample-accurate scheduling (stored as fixed-point * 1e9)
    pub fractional_tick_accumulator: AtomicI64,
    /// When true, the next playing callback dispatches MIDI at the playhead tick (play/seek).
    pub dispatch_playhead_tick: AtomicBool,
    /// Active loop region `[start, end)` in ticks; `None` while loop is off or the region is empty.
    pub loop_region: Option<(Tick, Tick)>,
    /// One absolute plugin deadline per callback, shared with subprocess plugin adapters.
    pub block_clock: Arc<BlockClock>,
    /// An offline render owns the devices and the transport (`audio/render`). The live
    /// callback holds a clone and outputs silence while it is set; transport commands are
    /// ignored.
    pub rendering: Arc<AtomicBool>,
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

    /// True while an offline render runs.
    pub fn is_rendering(&self) -> bool {
        self.rendering.load(Ordering::Acquire)
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
            render_scratch: RenderScratch::default(),
            tempo_map: TempoMap::default(),
            time_signature_map: TimeSignatureMap::default(),
            is_playing: AtomicBool::new(false),
            current_tick: AtomicI64::new(0),
            fractional_tick_accumulator: AtomicI64::new(0),
            dispatch_playhead_tick: AtomicBool::new(false),
            loop_region: None,
            block_clock: Arc::new(BlockClock::new()),
            rendering: Arc::new(AtomicBool::new(false)),
        }
    }
}

/// Look up a lane for an automation command, warning once when the track or lane is missing.
fn automation_lane_mut<'a>(
    state: &'a mut EngineState,
    track_id: TrackId,
    lane_id: &str,
    action: &str,
) -> Option<&'a mut AutomationLane> {
    let Some(track) = state.tracks.get_mut(&track_id) else {
        warn!(
            "Cannot {} automation lane: track {} not found",
            action, track_id
        );
        return None;
    };
    let lane = track.automation_lane_mut(lane_id);
    if lane.is_none() {
        warn!(
            "Cannot {} automation lane {}: not found on track {}",
            action, lane_id, track_id
        );
    }
    lane
}

/// Run `apply` on the Layer at `device_path`, warning when the channel, device or slot is missing.
fn with_layer(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: &DevicePath,
    slot: usize,
    apply: impl FnOnce(&mut super::devices::LayerDevice) -> bool,
) {
    let Some(device) = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(device_path))
    else {
        warn!("No device at channel {} path {}", channel_id, device_path);
        return;
    };
    let Some(layer) = device
        .as_any_mut()
        .downcast_mut::<super::devices::LayerDevice>()
    else {
        warn!(
            "Device at channel {} path {} is not a Layer",
            channel_id, device_path
        );
        return;
    };
    if !apply(layer) {
        warn!(
            "Layer slot {} not found at channel {} path {}",
            slot, channel_id, device_path
        );
    }
}

/// Run `apply` on the Sampler at `device_path`, warning when the channel or device is missing or
/// isn't a Sampler.
fn with_sampler(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: &DevicePath,
    apply: impl FnOnce(&mut super::devices::SamplerDevice),
) {
    let Some(device) = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(device_path))
    else {
        warn!("No device at channel {} path {}", channel_id, device_path);
        return;
    };
    match device
        .as_any_mut()
        .downcast_mut::<super::devices::SamplerDevice>()
    {
        Some(sampler) => apply(sampler),
        None => warn!(
            "Device at channel {} path {} is not a Sampler",
            channel_id, device_path
        ),
    }
}

/// Send `params` (from `device.parameters()`) to Godot: `param/count`, then one `param/info` each.
fn send_parameter_list(
    status_tx: &Sender<EngineStatus>,
    channel_id: ChannelId,
    device_path: DevicePath,
    device: &dyn super::devices::AudioDevice,
    params: Vec<super::devices::ParamInfo>,
) {
    let _ = status_tx.send(EngineStatus::PluginParameterCount {
        channel_id,
        device_path,
        count: params.len(),
    });
    for param in params {
        let _ = status_tx.send(EngineStatus::PluginParameterInfo {
            channel_id,
            device_path,
            param_id: param.id,
            name: param.name,
            min: param.min,
            max: param.max,
            default: param.default,
            group: device.parameter_group(param.id).to_string(),
            param_type: param.param_type,
            is_hidden: param.is_hidden,
            is_read_only: param.is_read_only,
            is_bypass: param.is_bypass,
            is_modulatable: param.is_modulatable,
            module: param.module,
            enum_values: param.enum_values,
            unit: param.unit,
            display: param.display,
        });
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
    if state.is_rendering()
        && matches!(
            cmd,
            AudioCommand::Play | AudioCommand::Pause | AudioCommand::Stop | AudioCommand::Seek(_)
        )
    {
        warn!(
            "Ignoring {:?}: the transport is unavailable while rendering",
            cmd
        );
        return None;
    }
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
            // Release clip notes; devices keep running so releases and effect tails ring out
            for channel in state.channels.values_mut() {
                channel.release_clip_notes();
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
            // Release clip notes; devices keep running so releases and effect tails ring out
            for channel in state.channels.values_mut() {
                channel.release_clip_notes();
            }
            for track in state.tracks.values_mut() {
                for instance in &mut track.clip_instances {
                    instance.playback_position = None;
                }
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
            // Release clip notes from the old position; tails keep ringing
            for channel in state.channels.values_mut() {
                channel.release_clip_notes();
            }
            for track in state.tracks.values_mut() {
                for instance in &mut track.clip_instances {
                    instance.playback_position = None;
                }
            }
            info!("Seeked to tick {}", tick);
        }
        AudioCommand::SetLoop {
            enabled,
            start,
            end,
        } => {
            state.loop_region = if enabled && start >= 0 && end > start {
                Some((start, end))
            } else {
                None
            };
            info!("Loop {:?}", state.loop_region);
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
        AudioCommand::SetChannelPanWidth { id, width } => {
            if let Some(channel) = state.channels.get_mut(&id) {
                channel.pan_width = width.clamp(-1.0, 1.0);
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

        // Automation lane management. These arms only mutate lane data — they deliberately send no
        // `EngineStatus`, so playback never rewrites what Godot has stored and saves.
        AudioCommand::CreateAutomationLane {
            track_id,
            lane_id,
            target,
        } => {
            let Some(track) = state.tracks.get_mut(&track_id) else {
                warn!(
                    "Cannot create automation lane on track {} (not found)",
                    track_id
                );
                return None;
            };
            if track.automation_lanes.iter().any(|l| l.id == lane_id) {
                warn!(
                    "Automation lane {} already exists on track {} - ignoring duplicate create",
                    lane_id, track_id
                );
                return None;
            }
            info!(
                "Automation lane {} created on track {} targeting {}",
                lane_id, track_id, target
            );
            track
                .automation_lanes
                .push(AutomationLane::new(lane_id, target));
        }
        AudioCommand::DeleteAutomationLane { track_id, lane_id } => {
            // Hand the parameter back to its base value before the lane disappears (REQ-004).
            super::automation::release_track_lane(state, track_id, &lane_id);
            let Some(track) = state.tracks.get_mut(&track_id) else {
                warn!(
                    "Cannot delete automation lane on track {} (not found)",
                    track_id
                );
                return None;
            };
            let before = track.automation_lanes.len();
            track.automation_lanes.retain(|l| l.id != lane_id);
            if track.automation_lanes.len() == before {
                warn!(
                    "Automation lane {} not found on track {} for delete",
                    lane_id, track_id
                );
            } else {
                info!(
                    "Automation lane {} deleted from track {}",
                    lane_id, track_id
                );
            }
        }
        AudioCommand::SetAutomationLaneBypass {
            track_id,
            lane_id,
            bypassed,
        } => {
            if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "bypass") {
                lane.bypassed = bypassed;
                info!(
                    "Automation lane {} on track {} bypass={}",
                    lane_id, track_id, bypassed
                );
                if bypassed {
                    // Restore the base value now rather than waiting for the next buffer, so a
                    // bypass with the transport stopped is audible immediately (REQ-009).
                    super::automation::release_track_lane(state, track_id, &lane_id);
                }
            }
        }
        AudioCommand::AddAutomationPoint {
            track_id,
            lane_id,
            point,
        } => {
            if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "add point") {
                if lane.insert_point(point) {
                    info!(
                        "Automation point {} added to lane {} on track {}: tick={} value={}",
                        point.id, lane_id, track_id, point.tick, point.value
                    );
                } else {
                    warn!(
                        "Automation point {} already exists in lane {} - ignoring duplicate add",
                        point.id, lane_id
                    );
                }
            }
        }
        AudioCommand::UpdateAutomationPoint {
            track_id,
            lane_id,
            point,
        } => {
            if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "update point") {
                if lane.update_point(point) {
                    info!(
                        "Automation point {} updated in lane {} on track {}: tick={} value={}",
                        point.id, lane_id, track_id, point.tick, point.value
                    );
                } else {
                    warn!(
                        "Automation point {} not found in lane {} for update",
                        point.id, lane_id
                    );
                }
            }
        }
        AudioCommand::RemoveAutomationPoint {
            track_id,
            lane_id,
            point_id,
        } => {
            if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "remove point") {
                if lane.remove_point(point_id) {
                    info!(
                        "Automation point {} removed from lane {} on track {}",
                        point_id, lane_id, track_id
                    );
                } else {
                    warn!(
                        "Automation point {} not found in lane {} for removal",
                        point_id, lane_id
                    );
                }
            }
        }
        AudioCommand::ClearAutomationLane { track_id, lane_id } => {
            if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "clear") {
                lane.clear_points();
                info!("Automation lane {} on track {} cleared", lane_id, track_id);
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
            release,
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
                        release,
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
            release,
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
                    clip_note.release = release;
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
                    instance.playback_position = None;

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
        AudioCommand::UpdateClipInstanceReverse {
            track_id,
            instance_id,
            reverse,
        } => {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                if let Some(instance) = track
                    .clip_instances
                    .iter_mut()
                    .find(|i| i.id == instance_id)
                {
                    instance.reverse = reverse;
                    info!("ClipInstance {} reverse updated: {}", instance_id, reverse);
                } else {
                    warn!(
                        "ClipInstance {} not found on track {}",
                        instance_id, track_id
                    );
                }
            } else {
                warn!("Track not found for update instance reverse: {}", track_id);
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
        AudioCommand::AddModulator {
            channel_id,
            device_path,
            mod_id,
            kind,
        } => {
            let Some(kind) = crate::audio::modulation::ModulatorKind::from_id(&kind) else {
                let message = format!("Unknown modulator kind '{kind}'");
                warn!("{}", message);
                log_engine_error(status_tx, &message);
                return None;
            };
            if let Err(e) = ensure_modulated(state, channel_id, &device_path) {
                warn!("{}", e);
                log_engine_error(status_tx, &e);
                return None;
            }
            let result = state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
                .and_then(|device| device.as_modulated_mut())
                .map(|modulated| modulated.add_modulator(mod_id, kind));
            match result {
                Some(Ok(())) => {
                    let _ = status_tx.send(EngineStatus::ModulatorAdded {
                        channel_id,
                        device_path,
                        mod_id,
                        kind: kind.id().to_string(),
                    });
                }
                Some(Err(e)) => {
                    warn!("{}", e);
                    log_engine_error(status_tx, &e);
                    unwrap_if_empty(state, channel_id, &device_path);
                }
                None => {
                    let message =
                        format!("No device at channel {channel_id} path {device_path} to modulate");
                    warn!("{}", message);
                    log_engine_error(status_tx, &message);
                }
            }
        }
        AudioCommand::RemoveModulator {
            channel_id,
            device_path,
            mod_id,
        } => {
            let result = state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
                .and_then(|device| device.as_modulated_mut())
                .map(|modulated| modulated.remove_modulator(mod_id));
            match result {
                Some(Ok(())) => {
                    unwrap_if_empty(state, channel_id, &device_path);
                    let _ = status_tx.send(EngineStatus::ModulatorRemoved {
                        channel_id,
                        device_path,
                        mod_id,
                    });
                }
                Some(Err(e)) => {
                    warn!("{}", e);
                    log_engine_error(status_tx, &e);
                }
                None => {
                    let message =
                        format!("No modulators at channel {channel_id} path {device_path}");
                    warn!("{}", message);
                    log_engine_error(status_tx, &message);
                }
            }
        }
        AudioCommand::SetModulatorParameter {
            channel_id,
            device_path,
            mod_id,
            param_id,
            value,
        } => {
            let result = state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
                .and_then(|device| device.as_modulated_mut())
                .map(|modulated| modulated.set_modulator_param(mod_id, param_id, value));
            match result {
                Some(Ok(value)) => {
                    let _ = status_tx.send(EngineStatus::ModulatorParamChanged {
                        channel_id,
                        device_path,
                        mod_id,
                        param_id,
                        value,
                    });
                }
                Some(Err(e)) => {
                    warn!("{}", e);
                    log_engine_error(status_tx, &e);
                }
                None => {
                    let message =
                        format!("No modulators at channel {channel_id} path {device_path}");
                    warn!("{}", message);
                    log_engine_error(status_tx, &message);
                }
            }
        }
        AudioCommand::SetModulatorRoute {
            channel_id,
            device_path,
            mod_id,
            target,
            amount,
        } => {
            let result = state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
                .and_then(|device| device.as_modulated_mut())
                .map(|modulated| modulated.set_modulator_route(mod_id, &target, amount));
            match result {
                Some(Ok(amount)) => {
                    let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
                        channel_id,
                        device_path,
                        mod_id,
                        target,
                        amount,
                    });
                }
                // A refused route (unknown or non-modulatable target, no such modulator) is
                // logged and echoed with amount 0, so the UI drops it.
                Some(Err(e)) => {
                    warn!("{}", e);
                    log_engine_error(status_tx, &e);
                    let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
                        channel_id,
                        device_path,
                        mod_id,
                        target,
                        amount: 0.0,
                    });
                }
                None => {
                    let message =
                        format!("No modulators at channel {channel_id} path {device_path}");
                    warn!("{}", message);
                    log_engine_error(status_tx, &message);
                    let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
                        channel_id,
                        device_path,
                        mod_id,
                        target,
                        amount: 0.0,
                    });
                }
            }
        }
        AudioCommand::ClearModulators {
            channel_id,
            device_path,
        } => {
            let Some(channel) = state.channels.get_mut(&channel_id) else {
                warn!("Channel {} not found for clear modulators", channel_id);
                return None;
            };
            let Some(device) = channel.device_at_path_mut(&device_path) else {
                warn!(
                    "Clear modulators for missing device at channel {} path {}",
                    channel_id, device_path
                );
                return None;
            };
            if let Some(modulated) = device.as_modulated_mut() {
                modulated.clear_modulators();
            }
            let _ = status_tx.send(EngineStatus::ModulatorsCleared {
                channel_id,
                device_path,
            });
            unwrap_if_empty(state, channel_id, &device_path);
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
            zone_id,
            req_id,
        } => with_sampler(state, channel_id, &device_path, |sampler| match zone_id {
            Some(zone_id) => sampler.begin_zone_load(zone_id, req_id),
            None => sampler.begin_sample_load(req_id),
        }),
        AudioCommand::LoadDeviceSample {
            channel_id,
            device_path,
            zone_id,
            req_id,
            samples,
            sample_rate,
            channels,
        } => with_sampler(state, channel_id, &device_path, |sampler| match zone_id {
            Some(zone_id) => {
                sampler.set_zone_sample(zone_id, &req_id, samples, channels, sample_rate)
            }
            None => sampler.set_sample(&req_id, samples, channels, sample_rate),
        }),
        AudioCommand::FailDeviceSampleLoad {
            channel_id,
            device_path,
            zone_id,
            req_id,
            message,
        } => with_sampler(state, channel_id, &device_path, |sampler| match zone_id {
            Some(zone_id) => sampler.fail_zone_load(zone_id, &req_id, &message),
            None => sampler.fail_sample_load(&req_id, &message),
        }),
        AudioCommand::SetSamplerMode {
            channel_id,
            device_path,
            multisample,
        } => with_sampler(state, channel_id, &device_path, |sampler| {
            sampler.set_multisample(multisample)
        }),
        AudioCommand::SetSamplerZone {
            channel_id,
            device_path,
            zone_id,
            settings,
        } => with_sampler(state, channel_id, &device_path, |sampler| {
            sampler.set_zone(zone_id, &settings)
        }),
        AudioCommand::RemoveSamplerZone {
            channel_id,
            device_path,
            zone_id,
        } => with_sampler(state, channel_id, &device_path, |sampler| {
            sampler.remove_zone(zone_id)
        }),
        AudioCommand::SetSamplerZoneGroup {
            channel_id,
            device_path,
            group_id,
            gain,
            mute,
            solo,
            play_mode,
        } => with_sampler(state, channel_id, &device_path, |sampler| {
            sampler.set_zone_group(group_id, gain, mute, solo, play_mode)
        }),
        AudioCommand::RemoveSamplerZoneGroup {
            channel_id,
            device_path,
            group_id,
        } => with_sampler(state, channel_id, &device_path, |sampler| {
            sampler.remove_zone_group(group_id)
        }),
        AudioCommand::SetSamplerFocus {
            channel_id,
            device_path,
            zone_id,
        } => with_sampler(state, channel_id, &device_path, |sampler| {
            sampler.set_focus(zone_id)
        }),
        AudioCommand::AuditionDevice {
            channel_id,
            device_path,
            note,
            velocity,
            is_note_on,
        } => {
            let Some(device) = state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
            else {
                warn!("No device at channel {} path {}", channel_id, device_path);
                return None;
            };
            let event = if is_note_on && velocity > 0 {
                NoteEvent::On {
                    note_id: AUDITION_NOTE_ID,
                    key: note,
                    velocity: velocity as f32 / 127.0,
                }
            } else {
                NoteEvent::Off {
                    note_id: AUDITION_NOTE_ID,
                    key: note,
                    release: crate::audio::midi_types::DEFAULT_RELEASE,
                }
            };
            device.mark_activity();
            device.send_note_event(&event, 0);
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
                    send_parameter_list(status_tx, channel_id, device_path, device, params);
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
        AudioCommand::GetDeviceState {
            channel_id,
            device_path,
        } => {
            // Godot missed a status (UDP drops under load): re-send what it can't recompute.
            let Some(device) = state
                .channels
                .get(&channel_id)
                .and_then(|channel| channel.device_at_path(&device_path))
            else {
                warn!(
                    "Device state requested for missing device at channel {} path {}",
                    channel_id, device_path
                );
                return None;
            };
            if let Some(loading_state) = device.loading_state() {
                let _ = status_tx.send(EngineStatus::DeviceLoadingStateChanged {
                    channel_id,
                    device_path,
                    state: loading_state,
                });
            }
            if device.has_dynamic_parameters() {
                let params = device.parameters();
                // Still loading: the list follows the load, as it normally does.
                if !params.is_empty() {
                    send_parameter_list(status_tx, channel_id, device_path, device, params);
                }
            }
            // Modulators live in the wrapper, not in the parameters: resend them as clear +
            // adds. The immutable borrow above ends here so we can reach the wrapper.
            if let Some(device) = state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
            {
                if let Some(sampler) = device
                    .as_any_mut()
                    .downcast_mut::<super::devices::SamplerDevice>()
                {
                    sampler.resend_zone_states();
                }
                resend_modulators(status_tx, channel_id, &device_path, device);
            }
        }
        AudioCommand::DeviceReady {
            channel_id,
            device_path,
            restored_values,
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
                        for &(param_id, value) in &restored_values {
                            subprocess_device.cache_parameter_value(param_id, value);
                        }
                    }
                    // A fresh plugin has no modulation offsets; push the current ones again
                    // (spec 018 Phase 5).
                    if let Some(modulated) = device.as_modulated_mut() {
                        modulated.resend_offsets();
                    }
                    let params = device.parameters();
                    if !params.is_empty() {
                        send_parameter_list(status_tx, channel_id, device_path, device, params);
                    }
                    // After the parameter list, so Godot doesn't reset them to defaults.
                    for (param_id, value) in restored_values {
                        let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                            channel_id,
                            device_path,
                            param_id,
                            value,
                        });
                    }
                }
            }
        }
        // Only non-plugin devices get here: the command worker handles subprocess plugins.
        AudioCommand::SavePluginState {
            channel_id,
            device_path,
            file_path,
        } => {
            let found = state
                .channels
                .get(&channel_id)
                .is_some_and(|channel| channel.device_at_path(&device_path).is_some());
            if !found {
                warn!(
                    "Save plugin state: no device at channel {} path {}",
                    channel_id, device_path
                );
            }
            // Always answer, so a project save waiting on it doesn't time out.
            let _ = status_tx.send(EngineStatus::PluginStateSaved {
                channel_id,
                device_path,
                file_path,
                size: if found { 0 } else { -1 },
            });
        }
        AudioCommand::LoadPluginState {
            channel_id,
            device_path,
            ..
        } => {
            warn!(
                "Load plugin state: no loaded plugin at channel {} path {}",
                channel_id, device_path
            );
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
        // The command worker handles these for subprocess plugins, the only ones they apply to
        AudioCommand::SetPluginGuiVisible {
            channel_id,
            device_path,
            ..
        }
        | AudioCommand::SetPluginGuiSize {
            channel_id,
            device_path,
            ..
        } => {
            warn!(
                "Plugin GUI visibility/size: no subprocess plugin at channel {} device {}",
                channel_id, device_path
            );
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

        AudioCommand::SetDrumSlotChokeTargets {
            channel_id,
            device_path,
            slot,
            mask,
        } => {
            if let Some(channel) = state.channels.get_mut(&channel_id) {
                if let Some(device) = channel.device_at_path_mut(&device_path) {
                    if let Some(drum) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::DrumMachineDevice>()
                    {
                        if !drum.set_slot_choke_targets(slot, mask) {
                            warn!(
                                "Drum slot {} choke targets {:#x} rejected at channel {} path {}",
                                slot, mask, channel_id, device_path
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

        AudioCommand::SetLayerSlotNoteMap {
            channel_id,
            device_path,
            slot,
            map,
        } => with_layer(state, channel_id, &device_path, slot, |layer| {
            layer.set_slot_note_map(slot, &map)
        }),
        AudioCommand::SetLayerSlotSeparateOut {
            channel_id,
            device_path,
            slot,
            separate,
        } => with_layer(state, channel_id, &device_path, slot, |layer| {
            layer.set_slot_separate_out(slot, separate)
        }),
        AudioCommand::AuditionLayerSlot {
            channel_id,
            device_path,
            slot,
            note,
            velocity,
            is_note_on,
        } => with_layer(state, channel_id, &device_path, slot, |layer| {
            layer.audition_slot(slot, note, velocity, is_note_on)
        }),

        // Slow commands that must run with the state lock released
        other @ (AudioCommand::ClearProject
        | AudioCommand::RemoveChannel { .. }
        | AudioCommand::AddDeviceToChannel { .. }
        | AudioCommand::RemoveDeviceFromChannel { .. }
        | AudioCommand::ClearChannelDevices { .. }
        | AudioCommand::ConfigureDeviceData { .. }
        | AudioCommand::SetTempoMap(_)
        | AudioCommand::SetTimeSignatureMap(_)
        | AudioCommand::ReloadDevice { .. }
        | AudioCommand::SetPluginHosting { .. }
        | AudioCommand::SetAudioConfig { .. }
        | AudioCommand::RequestAudioConfig
        | AudioCommand::RequestAudioDevices
        | AudioCommand::PipeWireGraph(_)
        | AudioCommand::ScanPlugins { .. }
        | AudioCommand::StartRender(_)
        | AudioCommand::CancelRender { .. }
        | AudioCommand::AdvertiseBuiltinDevices) => {
            warn!("{:?} must be handled by CommandWorker, ignoring", other);
        }
    }

    None
}

/// Wrap the device at `device_path` so it can carry modulators. A no-op when it is already
/// wrapped.
fn ensure_modulated(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: &DevicePath,
) -> Result<(), String> {
    let sample_rate = state.device_sample_rate;
    let channel = state
        .channels
        .get_mut(&channel_id)
        .ok_or_else(|| format!("no channel {channel_id}"))?;
    crate::audio::modulation::wrap_at_path(&mut channel.devices, device_path, sample_rate)
}

/// Drop the modulator wrapper at `device_path` once it holds no modulators.
fn unwrap_if_empty(state: &mut EngineState, channel_id: ChannelId, device_path: &DevicePath) {
    let Some(channel) = state.channels.get_mut(&channel_id) else {
        return;
    };
    let empty = channel
        .device_at_path_mut(device_path)
        .and_then(|device| device.as_modulated_mut())
        .map(|modulated| modulated.modulator_count() == 0)
        .unwrap_or(false);
    if empty {
        let _ = crate::audio::modulation::unwrap_at_path(&mut channel.devices, device_path);
    }
}

/// The modulator kinds the engine offers, as the `/builtin/modulator_*` batch: a header with
/// the count, one info per kind, then a completion.
pub fn modulator_kind_infos() -> Vec<EngineStatus> {
    let kind = super::modulation::ModulatorKind::COUNT;
    let mut out = Vec::with_capacity(kind + 2);
    out.push(EngineStatus::ModulatorKindsInfo { count: kind });
    for kind in super::modulation::ModulatorKind::ALL {
        let params = kind
            .table()
            .specs
            .iter()
            .map(|spec| BuiltinParamInfo::from(&spec.info()))
            .collect();
        out.push(EngineStatus::ModulatorKindInfo {
            id: kind.id().to_string(),
            name: kind.name().to_string(),
            bipolar: kind.bipolar(),
            params,
        });
    }
    out.push(EngineStatus::ModulatorKindsComplete { count: kind });
    out
}

/// Re-send a device's modulators after a missed status: `ModulatorsCleared`, then one
/// `ModulatorAdded` per modulator, each of its parameters and each route.
fn resend_modulators(
    status_tx: &Sender<EngineStatus>,
    channel_id: ChannelId,
    device_path: &DevicePath,
    device: &mut dyn super::devices::AudioDevice,
) {
    let Some(modulated) = device.as_modulated_mut() else {
        return;
    };
    if modulated.modulator_count() == 0 {
        return;
    }
    let _ = status_tx.send(EngineStatus::ModulatorsCleared {
        channel_id,
        device_path: *device_path,
    });
    for (mod_id, kind) in modulated.modulator_kinds() {
        let _ = status_tx.send(EngineStatus::ModulatorAdded {
            channel_id,
            device_path: *device_path,
            mod_id,
            kind: kind.id().to_string(),
        });
        for spec in kind.table().specs {
            if let Some(value) = modulated.get_modulator_param(mod_id, spec.id) {
                let _ = status_tx.send(EngineStatus::ModulatorParamChanged {
                    channel_id,
                    device_path: *device_path,
                    mod_id,
                    param_id: spec.id,
                    value,
                });
            }
        }
    }
    for (mod_id, target, amount) in modulated.modulator_routes() {
        let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
            channel_id,
            device_path: *device_path,
            mod_id,
            target,
            amount,
        });
    }
}

/// Forward a refused modulator command to Godot's `/log` so the UI can show why.
fn log_engine_error(status_tx: &Sender<EngineStatus>, message: &str) {
    let _ = status_tx.send(EngineStatus::LogMessage {
        level: "error".to_string(),
        message: message.to_string(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pan_width_command_clamps() {
        let mut state = EngineState::default();
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            &status_tx,
        );
        for (input, expected) in [(3.0, 1.0), (-3.0, -1.0), (0.4, 0.4)] {
            process_command(
                &mut state,
                AudioCommand::SetChannelPanWidth {
                    id: 2,
                    width: input,
                },
                128,
                &status_tx,
            );
            assert_eq!(state.channels[&2].pan_width, expected);
        }
    }

    #[test]
    fn modulator_kind_listing_advertises_release() {
        let infos = modulator_kind_infos();
        assert!(matches!(
            infos.first(),
            Some(EngineStatus::ModulatorKindsInfo { count: 7 })
        ));
        let release = infos.iter().find_map(|info| match info {
            EngineStatus::ModulatorKindInfo {
                id,
                name,
                bipolar,
                params,
            } if id == "release" => Some((name.clone(), *bipolar, params.len())),
            _ => None,
        });
        assert_eq!(release, Some(("Release".to_string(), false, 0)));
    }

    #[test]
    fn clip_note_command_stores_float_values() {
        let mut state = EngineState::default();
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        let clip_id = "c".to_string();
        process_command(
            &mut state,
            AudioCommand::CreateClip {
                id: clip_id.clone(),
                name: "C".to_string(),
                clip_type: "midi".to_string(),
            },
            128,
            &status_tx,
        );
        process_command(
            &mut state,
            AudioCommand::AddNoteToClip {
                clip_id: clip_id.clone(),
                note_id: 1,
                note: 60,
                start_tick: 0,
                duration_ticks: 480,
                velocity: 0.5039,
                release: 0.25,
            },
            128,
            &status_tx,
        );
        let note = &state.clips[&clip_id].midi_notes[0];
        assert_eq!((note.velocity, note.release), (0.5039, 0.25));

        process_command(
            &mut state,
            AudioCommand::UpdateClipNote {
                clip_id: clip_id.clone(),
                note_id: 1,
                note: 62,
                start_tick: 0,
                duration_ticks: 480,
                velocity: 0.75,
                release: 0.9,
            },
            128,
            &status_tx,
        );
        let note = &state.clips[&clip_id].midi_notes[0];
        assert_eq!((note.note, note.velocity, note.release), (62, 0.75, 0.9));
    }

    /// A channel 2 whose only device is `device`, plus the status receiver for `GetDeviceState`.
    fn device_state_replies(
        device: Box<dyn super::super::devices::AudioDevice>,
    ) -> Vec<EngineStatus> {
        let mut state = EngineState::default();
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            &status_tx,
        );
        state.channels.get_mut(&2).unwrap().devices.push(device);
        while status_rx.try_recv().is_ok() {}
        process_command(
            &mut state,
            AudioCommand::GetDeviceState {
                channel_id: 2,
                device_path: DevicePath::root(0),
            },
            128,
            &status_tx,
        );
        status_rx.try_iter().collect()
    }

    #[test]
    fn get_device_state_resends_loading_state() {
        let mut sampler = super::super::devices::SamplerDevice::new_for_metadata();
        sampler.begin_sample_load("req".to_string());
        let replies = device_state_replies(Box::new(sampler));
        assert_eq!(replies.len(), 1);
        assert!(matches!(
            &replies[0],
            EngineStatus::DeviceLoadingStateChanged { channel_id: 2, state, .. } if state == "loading"
        ));
    }

    #[test]
    fn sampler_zone_commands_route_to_device() {
        use super::super::devices::sampler_zones::{ZoneRanges, ZoneSettings};
        let mut state = EngineState::default();
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        let mut run = |state: &mut EngineState, cmd| {
            process_command(state, cmd, 128, &status_tx);
        };
        run(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
        );
        let sampler = super::super::devices::SamplerDevice::new(
            48_000.0,
            2,
            DevicePath::root(0),
            Some(status_tx.clone()),
        );
        state
            .channels
            .get_mut(&2)
            .unwrap()
            .devices
            .push(Box::new(sampler));
        let path = DevicePath::root(0);
        run(
            &mut state,
            AudioCommand::SetSamplerMode {
                channel_id: 2,
                device_path: path.clone(),
                multisample: true,
            },
        );
        run(
            &mut state,
            AudioCommand::SetSamplerZone {
                channel_id: 2,
                device_path: path.clone(),
                zone_id: 5,
                settings: ZoneSettings {
                    ranges: ZoneRanges::new((60, 72), (1, 127), (0, 0), (0, 0)),
                    ..ZoneSettings::default()
                },
            },
        );
        run(
            &mut state,
            AudioCommand::BeginLoadDeviceSample {
                channel_id: 2,
                device_path: path.clone(),
                zone_id: Some(5),
                req_id: "z5".to_string(),
            },
        );
        run(
            &mut state,
            AudioCommand::LoadDeviceSample {
                channel_id: 2,
                device_path: path.clone(),
                zone_id: Some(5),
                req_id: "z5".to_string(),
                samples: vec![0.5; 48_000],
                sample_rate: 48_000,
                channels: 1,
            },
        );
        let zone_states: Vec<(u32, String)> = status_rx
            .try_iter()
            .filter_map(|s| match s {
                EngineStatus::SamplerZoneLoadingState { zone_id, state, .. } => {
                    Some((zone_id, state))
                }
                _ => None,
            })
            .collect();
        assert_eq!(
            zone_states,
            vec![(5, "loading".to_string()), (5, "ready".to_string())]
        );

        let audition = |note, is_note_on| AudioCommand::AuditionDevice {
            channel_id: 2,
            device_path: DevicePath::root(0),
            note,
            velocity: 100,
            is_note_on,
        };
        let peak = |state: &mut EngineState| {
            let device = &mut state.channels.get_mut(&2).unwrap().devices[0];
            let mut out = vec![0.0f32; 512];
            device.process_block(&[0.0; 512], &mut out, 256);
            out.iter().fold(0.0f32, |m, x| m.max(x.abs()))
        };
        run(&mut state, audition(40, true));
        assert_eq!(peak(&mut state), 0.0, "outside the zone");
        run(&mut state, audition(64, true));
        assert!(peak(&mut state) > 0.1, "the zone plays");

        // state/get resends the zone's state; removing the zone silences it.
        run(
            &mut state,
            AudioCommand::GetDeviceState {
                channel_id: 2,
                device_path: path.clone(),
            },
        );
        assert!(status_rx.try_iter().any(|s| matches!(
            s,
            EngineStatus::SamplerZoneLoadingState { zone_id: 5, ref state, .. } if state == "ready"
        )));
        run(
            &mut state,
            AudioCommand::RemoveSamplerZone {
                channel_id: 2,
                device_path: path,
                zone_id: 5,
            },
        );
        peak(&mut state);
        assert_eq!(peak(&mut state), 0.0);
    }

    #[test]
    fn get_device_state_skips_empty_dynamic_parameter_list() {
        // An SFZ device with nothing loaded has no parameters to advertise yet.
        let sfizz = super::super::devices::SfizzDevice::new_for_metadata(48_000.0);
        let replies = device_state_replies(Box::new(sfizz));
        assert_eq!(replies.len(), 1);
        assert!(matches!(
            &replies[0],
            EngineStatus::DeviceLoadingStateChanged { state, .. } if state == "idle"
        ));
    }

    #[test]
    fn get_device_state_is_silent_for_fixed_devices() {
        let delay = super::super::devices::DelayDevice::new(48_000.0, 5000.0);
        assert!(device_state_replies(Box::new(delay)).is_empty());
    }

    /// Channel 2 with one Filter effect, the modulatable target the tests route into.
    fn modulator_test_state(status_tx: &Sender<EngineStatus>) -> EngineState {
        let mut state = EngineState::default();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            status_tx,
        );
        state.channels.get_mut(&2).unwrap().devices.push(
            super::super::devices::create_effect("sonara.builtin.filter", 48_000.0, 512)
                .expect("filter effect"),
        );
        state
    }

    fn modulator_count(state: &mut EngineState) -> usize {
        state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .map(|modulated| modulated.modulator_count())
            .unwrap_or(0)
    }

    #[test]
    fn modulator_commands_wrap_and_echo() {
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        let mut state = modulator_test_state(&status_tx);
        while status_rx.try_recv().is_ok() {}
        let path = DevicePath::root(0);

        process_command(
            &mut state,
            AudioCommand::AddModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                kind: "lfo".to_string(),
            },
            128,
            &status_tx,
        );
        assert_eq!(modulator_count(&mut state), 1, "the device is wrapped");
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorAdded { mod_id: 0, kind, .. }) if kind == "lfo"
        ));

        // LFO Rate (id 10) lands at the requested normalized value.
        process_command(
            &mut state,
            AudioCommand::SetModulatorParameter {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                param_id: 10,
                value: 0.75,
            },
            128,
            &status_tx,
        );
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorParamChanged { param_id: 10, value, .. })
                if (value - 0.75).abs() < 1e-6
        ));

        // Route to Filter Cutoff (id 2); amounts clamp and the echo carries the applied value.
        process_command(
            &mut state,
            AudioCommand::SetModulatorRoute {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                target: "param/2".to_string(),
                amount: 4.0,
            },
            128,
            &status_tx,
        );
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorRouteChanged { target, amount, .. })
                if target == "param/2" && amount == 1.0
        ));
        assert!(state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .unwrap()
            .modulator_routes()
            .iter()
            .any(|(_, target, amount)| target == "param/2" && *amount == 1.0));

        // An unknown target is refused: a `/log` error and an echo with amount 0.
        process_command(
            &mut state,
            AudioCommand::SetModulatorRoute {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                target: "param/99".to_string(),
                amount: 0.5,
            },
            128,
            &status_tx,
        );
        let refused: Vec<_> = status_rx.try_iter().collect();
        assert!(refused
            .iter()
            .any(|s| matches!(s, EngineStatus::LogMessage { level, .. } if level == "error")));
        assert!(refused.iter().any(|s| matches!(
            s,
            EngineStatus::ModulatorRouteChanged { target, amount, .. }
                if target == "param/99" && *amount == 0.0
        )));

        // Removing the last modulator unwraps the device.
        process_command(
            &mut state,
            AudioCommand::RemoveModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
            },
            128,
            &status_tx,
        );
        assert_eq!(modulator_count(&mut state), 0);
        assert!(state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .is_none());
    }

    #[test]
    fn clear_modulators_unwraps() {
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        let mut state = modulator_test_state(&status_tx);
        let path = DevicePath::root(0);
        process_command(
            &mut state,
            AudioCommand::AddModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                kind: "ad".to_string(),
            },
            128,
            &status_tx,
        );
        while status_rx.try_recv().is_ok() {}
        process_command(
            &mut state,
            AudioCommand::ClearModulators {
                channel_id: 2,
                device_path: path,
            },
            128,
            &status_tx,
        );
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorsCleared { .. })
        ));
        assert!(state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .is_none());
    }

    #[test]
    fn get_device_state_resends_modulators() {
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        let mut state = modulator_test_state(&status_tx);
        let path = DevicePath::root(0);
        process_command(
            &mut state,
            AudioCommand::AddModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                kind: "lfo".to_string(),
            },
            128,
            &status_tx,
        );
        process_command(
            &mut state,
            AudioCommand::SetModulatorRoute {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                target: "param/2".to_string(),
                amount: 0.5,
            },
            128,
            &status_tx,
        );
        let (get_tx, get_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::GetDeviceState {
                channel_id: 2,
                device_path: path,
            },
            128,
            &get_tx,
        );
        let replies: Vec<_> = get_rx.try_iter().collect();
        assert!(matches!(replies[0], EngineStatus::ModulatorsCleared { .. }));
        assert!(replies.iter().any(|s| matches!(
            s,
            EngineStatus::ModulatorAdded { mod_id: 0, kind, .. } if kind == "lfo"
        )));
        assert!(replies
            .iter()
            .any(|s| matches!(s, EngineStatus::ModulatorParamChanged { param_id: 10, .. })));
        assert!(replies.iter().any(|s| matches!(
            s,
            EngineStatus::ModulatorRouteChanged { target, amount: 0.5, .. }
                if target == "param/2"
        )));
    }

    /// A project save waits for every `state/save` it sent, so a device without plugin state
    /// must still answer: size 0 for a device that has none, -1 for no device at all.
    #[test]
    fn save_plugin_state_always_answers() {
        let mut state = EngineState::default();
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            &status_tx,
        );
        state.channels.get_mut(&2).unwrap().devices.push(Box::new(
            super::super::devices::PolySynthDevice::new(48_000.0),
        ));
        while status_rx.try_recv().is_ok() {}

        for (position, expected) in [(0, 0), (5, -1)] {
            process_command(
                &mut state,
                AudioCommand::SavePluginState {
                    channel_id: 2,
                    device_path: DevicePath::root(position),
                    file_path: "/tmp/unused.bin".to_string(),
                },
                128,
                &status_tx,
            );
            let replies: Vec<EngineStatus> = status_rx.try_iter().collect();
            assert_eq!(replies.len(), 1);
            assert!(matches!(
                &replies[0],
                EngineStatus::PluginStateSaved { channel_id: 2, size, file_path, .. }
                    if *size == expected && file_path == "/tmp/unused.bin"
            ));
        }
    }
}
