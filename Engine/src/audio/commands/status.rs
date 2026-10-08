//! Statuses the engine sends back to Godot, and the info types some of them carry.

use crate::audio::clip::ClipLoadState;
use crate::audio::devices::DevicePath;
use crate::audio::types::{ChannelId, ClipId, Tick};
use std::path::PathBuf;

/// Parameter information for builtin devices
#[derive(Debug, Clone)]
pub struct BuiltinParamInfo {
    pub id: u32,
    pub name: String,
    pub unit: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub param_type: crate::audio::devices::ParamType,
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

impl From<&crate::audio::devices::ParamInfo> for BuiltinParamInfo {
    fn from(p: &crate::audio::devices::ParamInfo) -> Self {
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
    pub active: Option<crate::audio::stream::StreamInfo>,
    pub requested: crate::audio::stream::StreamRequest,
    /// The PipeWire graph quantum and rate (0 when unknown or not on PipeWire).
    pub graph_quantum: u32,
    pub graph_rate: u32,
    /// Graph/stream conflict for Settings, "" when none.
    pub mismatch: String,
    /// Why the running config differs from the request (device missing, rate unsupported), "".
    pub notice: String,
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
        default_modulators: Vec<crate::audio::devices::DefaultModulator>,
    },
    BuiltinDevicesComplete {
        count: usize,
    },

    // Audio device settings (Phase 7)
    /// One output device, in answer to `RequestAudioDevices`.
    AudioDeviceInfo(crate::audio::stream::OutputDeviceInfo),
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
        param_type: crate::audio::devices::ParamType,
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
