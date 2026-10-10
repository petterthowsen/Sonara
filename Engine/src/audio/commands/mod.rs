//! Commands from the OSC server and the facts the audio engine reports back.
//!
//! `AudioCommand` is one flat enum. `process_command` applies the fast ones to the `EngineState`
//! on the command thread; each domain module holds the functions for its commands, and the
//! dispatcher here has one arm per command.

mod channel;
mod clip;
mod device;
mod device_data;
mod layer;
mod modulation;
mod plugin;
mod sampler;
mod status;
mod track;
mod transport;

pub use modulation::modulator_kind_infos;
pub use status::{AudioConfigReport, BuiltinParamInfo, EngineStatus};

use crate::audio::devices::AudioDevice;

use crate::audio::automation::{
    AutomationLaneId, AutomationPoint, AutomationPointId, AutomationTarget,
};
use crate::audio::clip::StretchMode;
use crate::audio::devices::sampler::zones::{GroupPlayMode, ZoneSettings};
use crate::audio::devices::DevicePath;
use crate::audio::project::ProjectSettings;
use crate::audio::state::EngineState;
use crate::audio::types::{ChannelId, ClipId, ClipInstanceId, MidiNote, NoteId, Tick, TrackId};
use std::path::PathBuf;
use std::time::Instant;
use tracing::warn;

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
    /// Project scale as a 12-bit pitch-class mask (bit 0 = C), 0 = none (spec 027).
    SetProjectScale(u16),

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
    /// Set an audio clip's stretch mode and tempo (BPM of the material) and re-seat its instances.
    SetClipTiming {
        clip_id: ClipId,
        mode: StretchMode,
        bpm: f32,
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
        /// VST3 search paths; empty means the built-in defaults.
        vst3_paths: Vec<PathBuf>,
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

/// Run `apply` on the device of type `T` at `device_path`. A missing channel, a missing device or
/// the wrong device type is logged as `"{cmd}: {reason}"` and returns `None`.
fn with_device<T: AudioDevice + 'static, R>(
    state: &mut EngineState,
    cmd: &str,
    channel_id: ChannelId,
    device_path: &DevicePath,
    apply: impl FnOnce(&mut T) -> R,
) -> Option<R> {
    match state.device_as_mut::<T>(channel_id, device_path) {
        Ok(device) => Some(apply(device)),
        Err(e) => {
            warn!("{cmd}: {e}");
            None
        }
    }
}

/// What applying a command produced, handled by the caller after it releases the state lock.
///
/// Sending a status can block (the channel is bounded) and dropping a channel, clip or device
/// frees memory. Neither belongs under the state lock: while it is held, the audio callback
/// misses its `try_lock` and outputs silence.
#[derive(Default)]
pub struct CommandEffects {
    /// Statuses for Godot, in the order the command produced them.
    pub statuses: Vec<EngineStatus>,
    /// Objects the command removed from the state, dropped after the lock is released.
    pub trash: Vec<Box<dyn std::any::Any + Send>>,
}

impl CommandEffects {
    /// Take the oldest queued status, as a test would read it off a channel.
    #[cfg(test)]
    pub(crate) fn next_status(&mut self) -> Option<EngineStatus> {
        (!self.statuses.is_empty()).then(|| self.statuses.remove(0))
    }

    /// Queue `value` to be dropped by the caller once the state lock is released.
    pub fn discard<T: Send + 'static>(&mut self, value: T) {
        self.trash.push(Box::new(value));
    }
}

/// Apply a command to the engine state. Runs on the command thread with the state lock held, so
/// it must stay fast; slow commands are handled by `CommandWorker` instead.
///
/// Statuses for Godot and removed objects are collected in `effects`; the caller sends and drops
/// them after it releases the lock, in order.
pub fn process_command(
    state: &mut EngineState,
    cmd: AudioCommand,
    buffer_size: usize,
    effects: &mut CommandEffects,
) {
    if let Some(status) = dispatch(state, cmd, buffer_size, effects) {
        effects.statuses.push(status);
    }
}

/// The dispatcher: each arm calls the function for that command in the domain module
/// (`transport`, `channel`, `track`, `clip`, `device`, ...). Returns the status the command
/// produced, if any; statuses it needs to send earlier are pushed to `effects` directly, so
/// they come first.
fn dispatch(
    state: &mut EngineState,
    cmd: AudioCommand,
    buffer_size: usize,
    effects: &mut CommandEffects,
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
        AudioCommand::InitProject(settings) => {
            transport::init_project(state, settings, buffer_size)
        }
        AudioCommand::Play => return transport::play(state),
        AudioCommand::Pause => return transport::pause(state),
        AudioCommand::Stop => return transport::stop(state, effects),
        AudioCommand::Seek(tick) => transport::seek(state, tick),
        AudioCommand::SetLoop {
            enabled,
            start,
            end,
        } => transport::set_loop(state, enabled, start, end),
        AudioCommand::SetTempo(tempo) => transport::set_tempo(state, tempo),
        AudioCommand::SetTimeSignature(num, den) => transport::set_time_signature(state, num, den),
        AudioCommand::SetProjectScale(mask) => transport::set_project_scale(state, mask),
        AudioCommand::CreateChannel { id, name } => {
            channel::create_channel(state, id, name, buffer_size)
        }
        AudioCommand::SetChannelVolume { id, db } => channel::set_channel_volume(state, id, db),
        AudioCommand::SetChannelPan {
            id,
            pan_left,
            pan_right,
        } => channel::set_channel_pan(state, id, pan_left, pan_right),
        AudioCommand::SetChannelPanMode { id, mode } => {
            channel::set_channel_pan_mode(state, id, mode)
        }
        AudioCommand::SetChannelPanWidth { id, width } => {
            channel::set_channel_pan_width(state, id, width)
        }
        AudioCommand::SetChannelMute { id, mute } => channel::set_channel_mute(state, id, mute),
        AudioCommand::SetChannelSolo { id, solo } => channel::set_channel_solo(state, id, solo),
        AudioCommand::SetChannelRoute { id, output_id } => {
            channel::set_channel_route(state, id, output_id)
        }
        AudioCommand::SetAuxOut {
            id,
            bus_index,
            target_id,
        } => channel::set_aux_out(state, id, bus_index, target_id),
        AudioCommand::SetMidiInputDevice {
            channel_id,
            device_id,
        } => channel::set_midi_input_device(state, channel_id, device_id),
        AudioCommand::SetRecordArmed { channel_id, armed } => {
            channel::set_record_armed(state, channel_id, armed)
        }
        AudioCommand::MidiEvent {
            channel_id,
            message_type,
            midi_channel,
            note,
            velocity,
            received_at,
        } => channel::midi_event(
            state,
            channel_id,
            message_type,
            midi_channel,
            note,
            velocity,
            received_at,
        ),
        AudioCommand::AddSend {
            channel_id,
            target_channel_id,
            amount_db,
            pre_fader,
        } => channel::add_send(state, channel_id, target_channel_id, amount_db, pre_fader),
        AudioCommand::RemoveSend {
            channel_id,
            target_channel_id,
        } => channel::remove_send(state, channel_id, target_channel_id),
        AudioCommand::SetSendAmount {
            channel_id,
            target_channel_id,
            amount_db,
        } => channel::set_send_amount(state, channel_id, target_channel_id, amount_db),
        AudioCommand::SetSendPreFader {
            channel_id,
            target_channel_id,
            pre_fader,
        } => channel::set_send_pre_fader(state, channel_id, target_channel_id, pre_fader),
        AudioCommand::SetSendMute {
            channel_id,
            target_channel_id,
            muted,
        } => channel::set_send_mute(state, channel_id, target_channel_id, muted),
        AudioCommand::CreateTrack { id, channel_id } => track::create_track(state, id, channel_id),
        AudioCommand::SetTrackRoute { id, channel_id } => {
            track::set_track_route(state, id, channel_id)
        }
        // Automation lane management. These arms only mutate lane data — they deliberately send no
        // `EngineStatus`, so playback never rewrites what Godot has stored and saves.
        AudioCommand::CreateAutomationLane {
            track_id,
            lane_id,
            target,
        } => return track::create_automation_lane(state, track_id, lane_id, target),
        AudioCommand::DeleteAutomationLane { track_id, lane_id } => {
            return track::delete_automation_lane(state, track_id, lane_id)
        }
        AudioCommand::SetAutomationLaneBypass {
            track_id,
            lane_id,
            bypassed,
        } => track::set_automation_lane_bypass(state, track_id, lane_id, bypassed),
        AudioCommand::AddAutomationPoint {
            track_id,
            lane_id,
            point,
        } => track::add_automation_point(state, track_id, lane_id, point),
        AudioCommand::UpdateAutomationPoint {
            track_id,
            lane_id,
            point,
        } => track::update_automation_point(state, track_id, lane_id, point),
        AudioCommand::RemoveAutomationPoint {
            track_id,
            lane_id,
            point_id,
        } => track::remove_automation_point(state, track_id, lane_id, point_id),
        AudioCommand::ClearAutomationLane { track_id, lane_id } => {
            track::clear_automation_lane(state, track_id, lane_id)
        }
        AudioCommand::CreateClip {
            id,
            name,
            clip_type,
        } => clip::create_clip(state, id, name, clip_type),
        AudioCommand::RemoveClip { id } => clip::remove_clip(state, id, effects),
        AudioCommand::AddNoteToClip {
            clip_id,
            note_id,
            note,
            start_tick,
            duration_ticks,
            velocity,
            release,
        } => clip::add_note_to_clip(
            state,
            clip_id,
            note_id,
            note,
            start_tick,
            duration_ticks,
            velocity,
            release,
        ),
        AudioCommand::RemoveNoteFromClip { clip_id, note_id } => {
            clip::remove_note_from_clip(state, clip_id, note_id)
        }
        AudioCommand::UpdateClipNote {
            clip_id,
            note_id,
            note,
            start_tick,
            duration_ticks,
            velocity,
            release,
        } => clip::update_clip_note(
            state,
            clip_id,
            note_id,
            note,
            start_tick,
            duration_ticks,
            velocity,
            release,
        ),
        AudioCommand::BeginLoadAudioClip {
            clip_id,
            req_id,
            source_path,
        } => return clip::begin_load_audio_clip(state, clip_id, req_id, source_path, effects),
        AudioCommand::LoadAudioClip {
            clip_id,
            req_id,
            source_path,
            cache_key,
            samples,
            sample_rate,
            channels,
        } => {
            return clip::load_audio_clip(
                state,
                clip_id,
                req_id,
                source_path,
                cache_key,
                samples,
                sample_rate,
                channels,
                effects,
            )
        }
        AudioCommand::FailAudioClipLoad {
            clip_id,
            req_id,
            message,
        } => return clip::fail_audio_clip_load(state, clip_id, req_id, message, effects),
        AudioCommand::CreateClipInstance {
            track_id,
            instance_id,
            clip_id,
            start_tick,
            duration_ticks,
        } => clip::create_clip_instance(
            state,
            track_id,
            instance_id,
            clip_id,
            start_tick,
            duration_ticks,
        ),
        AudioCommand::RemoveClipInstance {
            track_id,
            instance_id,
        } => clip::remove_clip_instance(state, track_id, instance_id),
        AudioCommand::UpdateClipInstancePosition {
            track_id,
            instance_id,
            start_tick,
            duration_ticks,
            clip_offset,
        } => clip::update_clip_instance_position(
            state,
            track_id,
            instance_id,
            start_tick,
            duration_ticks,
            clip_offset,
        ),
        AudioCommand::UpdateClipInstanceTranspose {
            track_id,
            instance_id,
            transpose,
        } => clip::update_clip_instance_transpose(state, track_id, instance_id, transpose),
        AudioCommand::UpdateClipInstanceGain {
            track_id,
            instance_id,
            gain_db,
        } => clip::update_clip_instance_gain(state, track_id, instance_id, gain_db),
        AudioCommand::UpdateClipInstanceMute {
            track_id,
            instance_id,
            muted,
        } => clip::update_clip_instance_mute(state, track_id, instance_id, muted),
        AudioCommand::UpdateClipInstanceLoop {
            track_id,
            instance_id,
            enabled,
            start_tick,
            length_ticks,
        } => clip::update_clip_instance_loop(
            state,
            track_id,
            instance_id,
            enabled,
            start_tick,
            length_ticks,
        ),
        AudioCommand::UpdateClipInstanceReverse {
            track_id,
            instance_id,
            reverse,
        } => clip::update_clip_instance_reverse(state, track_id, instance_id, reverse),
        AudioCommand::SetClipTiming { clip_id, mode, bpm } => {
            clip::set_clip_timing(state, clip_id, mode, bpm)
        }
        AudioCommand::MoveDevice {
            channel_id,
            parent_path,
            from_position,
            to_position,
        } => device::move_device(state, channel_id, parent_path, from_position, to_position),
        AudioCommand::SetDeviceParameter {
            channel_id,
            device_path,
            param_id,
            value,
        } => {
            return device::set_device_parameter(
                state,
                channel_id,
                device_path,
                param_id,
                value,
                effects,
            )
        }
        AudioCommand::AddModulator {
            channel_id,
            device_path,
            mod_id,
            kind,
        } => {
            return modulation::add_modulator(state, channel_id, device_path, mod_id, kind, effects)
        }
        AudioCommand::RemoveModulator {
            channel_id,
            device_path,
            mod_id,
        } => modulation::remove_modulator(state, channel_id, device_path, mod_id, effects),
        AudioCommand::SetModulatorParameter {
            channel_id,
            device_path,
            mod_id,
            param_id,
            value,
        } => modulation::set_modulator_parameter(
            state,
            channel_id,
            device_path,
            mod_id,
            param_id,
            value,
            effects,
        ),
        AudioCommand::SetModulatorRoute {
            channel_id,
            device_path,
            mod_id,
            target,
            amount,
        } => modulation::set_modulator_route(
            state,
            channel_id,
            device_path,
            mod_id,
            target,
            amount,
            effects,
        ),
        AudioCommand::ClearModulators {
            channel_id,
            device_path,
        } => return modulation::clear_modulators(state, channel_id, device_path, effects),
        AudioCommand::SetDeviceActive {
            channel_id,
            device_path,
            active,
        } => device::set_device_active(state, channel_id, device_path, active, effects),
        AudioCommand::SetDeviceEnabled {
            channel_id,
            device_path,
            enabled,
        } => device::set_device_enabled(state, channel_id, device_path, enabled, effects),
        AudioCommand::LoadDeviceFile {
            channel_id,
            device_path,
            file_path,
        } => device::load_device_file(state, channel_id, device_path, file_path),
        AudioCommand::BeginLoadDeviceSample {
            channel_id,
            device_path,
            zone_id,
            req_id,
        } => sampler::begin_load_device_sample(state, channel_id, device_path, zone_id, req_id),
        AudioCommand::LoadDeviceSample {
            channel_id,
            device_path,
            zone_id,
            req_id,
            samples,
            sample_rate,
            channels,
        } => sampler::load_device_sample(
            state,
            channel_id,
            device_path,
            zone_id,
            req_id,
            samples,
            sample_rate,
            channels,
            effects,
        ),
        AudioCommand::FailDeviceSampleLoad {
            channel_id,
            device_path,
            zone_id,
            req_id,
            message,
        } => sampler::fail_device_sample_load(
            state,
            channel_id,
            device_path,
            zone_id,
            req_id,
            message,
        ),
        AudioCommand::SetSamplerMode {
            channel_id,
            device_path,
            multisample,
        } => sampler::set_sampler_mode(state, channel_id, device_path, multisample),
        AudioCommand::SetSamplerZone {
            channel_id,
            device_path,
            zone_id,
            settings,
        } => sampler::set_sampler_zone(state, channel_id, device_path, zone_id, settings),
        AudioCommand::RemoveSamplerZone {
            channel_id,
            device_path,
            zone_id,
        } => sampler::remove_sampler_zone(state, channel_id, device_path, zone_id),
        AudioCommand::SetSamplerZoneGroup {
            channel_id,
            device_path,
            group_id,
            gain,
            mute,
            solo,
            play_mode,
        } => sampler::set_sampler_zone_group(
            state,
            channel_id,
            device_path,
            group_id,
            gain,
            mute,
            solo,
            play_mode,
        ),
        AudioCommand::RemoveSamplerZoneGroup {
            channel_id,
            device_path,
            group_id,
        } => sampler::remove_sampler_zone_group(state, channel_id, device_path, group_id),
        AudioCommand::SetSamplerFocus {
            channel_id,
            device_path,
            zone_id,
        } => sampler::set_sampler_focus(state, channel_id, device_path, zone_id),
        AudioCommand::AuditionDevice {
            channel_id,
            device_path,
            note,
            velocity,
            is_note_on,
        } => {
            return device::audition_device(
                state,
                channel_id,
                device_path,
                note,
                velocity,
                is_note_on,
            )
        }
        AudioCommand::GetPluginParameters {
            channel_id,
            device_path,
        } => device::get_plugin_parameters(state, channel_id, device_path, effects),
        AudioCommand::GetDeviceState {
            channel_id,
            device_path,
        } => return device::get_device_state(state, channel_id, device_path, effects),
        AudioCommand::DeviceReady {
            channel_id,
            device_path,
            restored_values,
        } => device::device_ready(state, channel_id, device_path, restored_values, effects),
        // Only non-plugin devices get here: the command worker handles subprocess plugins.
        AudioCommand::SavePluginState {
            channel_id,
            device_path,
            file_path,
        } => plugin::save_plugin_state(state, channel_id, device_path, file_path, effects),
        AudioCommand::LoadPluginState {
            channel_id,
            device_path,
            ..
        } => plugin::load_plugin_state(channel_id, device_path),
        AudioCommand::OpenPluginGui {
            channel_id,
            device_path,
            ..
        } => plugin::open_plugin_gui(channel_id, device_path),
        AudioCommand::ClosePluginGui {
            channel_id,
            device_path,
        } => plugin::close_plugin_gui(channel_id, device_path),
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
        } => plugin::plugin_gui_unavailable(channel_id, device_path),
        AudioCommand::SubscribeDeviceData {
            channel_id,
            device_path,
            data_type,
        } => device_data::subscribe_device_data(state, channel_id, device_path, data_type),
        AudioCommand::UnsubscribeDeviceData {
            channel_id,
            device_path,
            data_type,
        } => device_data::unsubscribe_device_data(state, channel_id, device_path, data_type),
        AudioCommand::SetLayerSlotVolume {
            channel_id,
            device_path,
            slot,
            volume,
        } => layer::set_layer_slot_volume(state, channel_id, device_path, slot, volume),
        AudioCommand::SetLayerSlotMute {
            channel_id,
            device_path,
            slot,
            mute,
        } => layer::set_layer_slot_mute(state, channel_id, device_path, slot, mute),
        AudioCommand::SetLayerSlotSolo {
            channel_id,
            device_path,
            slot,
            solo,
        } => layer::set_layer_slot_solo(state, channel_id, device_path, slot, solo),
        AudioCommand::SetDrumSlotNote {
            channel_id,
            device_path,
            slot,
            note,
        } => layer::set_drum_slot_note(state, channel_id, device_path, slot, note),
        AudioCommand::SetDrumSlotChokeTargets {
            channel_id,
            device_path,
            slot,
            mask,
        } => layer::set_drum_slot_choke_targets(state, channel_id, device_path, slot, mask),
        AudioCommand::SetLayerSlotNoteMap {
            channel_id,
            device_path,
            slot,
            map,
        } => layer::set_layer_slot_note_map(state, channel_id, device_path, slot, map),
        AudioCommand::SetLayerSlotSeparateOut {
            channel_id,
            device_path,
            slot,
            separate,
        } => layer::set_layer_slot_separate_out(state, channel_id, device_path, slot, separate),
        AudioCommand::AuditionLayerSlot {
            channel_id,
            device_path,
            slot,
            note,
            velocity,
            is_note_on,
        } => layer::audition_layer_slot(
            state,
            channel_id,
            device_path,
            slot,
            note,
            velocity,
            is_note_on,
        ),
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Stop sends the playhead reset first and the play state second; Godot relies on the order.
    #[test]
    fn stop_collects_statuses_in_order() {
        let mut state = EngineState::default();
        let mut effects = CommandEffects::default();
        process_command(&mut state, AudioCommand::Stop, 64, &mut effects);
        assert!(matches!(
            effects.statuses.as_slice(),
            [
                EngineStatus::PlayheadUpdate(0),
                EngineStatus::PlayingStateChanged(false)
            ]
        ));
    }

    /// A removed clip is handed back in `trash` instead of being dropped under the lock.
    #[test]
    fn removed_clip_goes_to_trash() {
        let mut state = EngineState::default();
        let mut effects = CommandEffects::default();
        for cmd in [
            AudioCommand::CreateClip {
                id: "c".to_string(),
                name: "C".to_string(),
                clip_type: "audio".to_string(),
            },
            AudioCommand::RemoveClip {
                id: "c".to_string(),
            },
        ] {
            process_command(&mut state, cmd, 64, &mut effects);
        }
        assert!(state.clips.is_empty());
        assert_eq!(effects.trash.len(), 1);
        assert!(effects.statuses.is_empty());
    }

    /// Replacing an audio clip's PCM discards the old buffer through `trash`.
    #[test]
    fn loading_audio_discards_the_old_pcm() {
        let mut state = EngineState::default();
        let mut effects = CommandEffects::default();
        let load = |req: &str, samples: Vec<f32>| AudioCommand::LoadAudioClip {
            clip_id: "c".to_string(),
            req_id: req.to_string(),
            source_path: "x.wav".to_string(),
            cache_key: None,
            samples,
            sample_rate: 48_000,
            channels: 2,
        };
        process_command(
            &mut state,
            AudioCommand::CreateClip {
                id: "c".to_string(),
                name: "C".to_string(),
                clip_type: "audio".to_string(),
            },
            64,
            &mut effects,
        );
        process_command(&mut state, load("a", vec![0.0; 8]), 64, &mut effects);
        let before = effects.trash.len();
        process_command(&mut state, load("b", vec![0.5; 8]), 64, &mut effects);
        assert_eq!(effects.trash.len(), before + 1);
        assert_eq!(state.clips["c"].audio_samples, vec![0.5; 8]);
    }

    /// One lane per target per track (REQ-011): a second `channel/cc/1` lane is refused and
    /// the first lane is untouched, while two different CCs coexist.
    #[test]
    fn create_automation_lane_refuses_a_duplicate_target() {
        use crate::audio::track::Track;

        let mut state = EngineState::default();
        state.tracks.insert(1, Track::new(1, 2));
        let cc1 = AutomationTarget::MidiCc { cc: 1 };
        let cc11 = AutomationTarget::MidiCc { cc: 11 };

        assert!(
            track::create_automation_lane(&mut state, 1, "cc1".to_string(), cc1.clone()).is_none()
        );
        // A different lane id for the same target is refused; the first lane is untouched.
        assert!(
            track::create_automation_lane(&mut state, 1, "cc1-again".to_string(), cc1.clone())
                .is_none()
        );
        assert_eq!(state.tracks[&1].automation_lanes.len(), 1);
        assert_eq!(state.tracks[&1].automation_lanes[0].id, "cc1");
        assert_eq!(state.tracks[&1].automation_lanes[0].target, cc1);

        // A different controller gets its own lane.
        assert!(
            track::create_automation_lane(&mut state, 1, "cc11".to_string(), cc11.clone())
                .is_none()
        );
        assert_eq!(state.tracks[&1].automation_lanes.len(), 2);
        assert_eq!(state.tracks[&1].automation_lanes[1].target, cc11);

        // The rule is generic on the target, not CC-specific: a second device-param lane for
        // the same target is refused too.
        let param = AutomationTarget::DeviceParam {
            device_path: DevicePath::root(0),
            param_id: 5,
        };
        assert!(
            track::create_automation_lane(&mut state, 1, "param".to_string(), param.clone())
                .is_none()
        );
        assert!(
            track::create_automation_lane(&mut state, 1, "param-again".to_string(), param)
                .is_none()
        );
        assert_eq!(state.tracks[&1].automation_lanes.len(), 3);
    }
}
