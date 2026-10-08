//! Command thread: applies `AudioCommand`s to the engine state shared with the audio callback.
//!
//! The audio callback gives up on a buffer if it can't take the state lock quickly, so this
//! worker holds the lock only to read or swap state. Slow work (plugin scans, building and
//! dropping devices, plugin subprocess round-trips) runs with the lock released. This is safe
//! because the worker is the only thread that adds or removes channels and devices.

use crossbeam::channel::{Receiver, RecvTimeoutError, Sender};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tracing::warn;

use super::block_clock::BlockClock;
use super::commands::{process_command, AudioCommand, CommandEffects, EngineStatus};
use super::devices::clap_host::PluginScanner;
use super::devices::{DeviceFactory, DevicePath};
use super::ipc::ProcessManager;
use super::pipewire::GraphInfo;
use super::render::RenderHandle;
use super::state::EngineState;
use super::stream::{StreamControl, StreamRequest};
use super::types::ChannelId;

mod audio_config;
use device_tick::{PluginStatsLog, PluginStatsReport};
mod device_tick;
mod devices;
mod plugins;
mod project;
mod render;

/// How often the command thread services devices between commands: plugin parameter changes,
/// queued automation writes, plugin crash checks and SFZ parameter lists. This is work the audio
/// callback must not do itself.
const DEVICE_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// The output stream settings the command thread applies (Phase 7).
struct AudioSettings {
    /// What Godot asked for (`/audio/config/set`); kept when the running stream differs.
    request: StreamRequest,
    /// Period the running stream was opened with: the request's, or larger for PipeWire's
    /// quantum. 0 while no stream runs.
    opened_period: u32,
    /// Last PipeWire graph the monitor reported.
    graph: Option<GraphInfo>,
    /// Why the running config differs from the request, for Settings.
    notice: String,
    /// Last graph/stream conflict reported, so each new one is logged once.
    mismatch: String,
}

/// Owns the command thread's resources and applies commands to the shared engine state.
pub struct CommandWorker {
    state: Arc<Mutex<EngineState>>,
    status_tx: Sender<EngineStatus>,
    max_buffer_size: usize,
    process_manager: Arc<ProcessManager>,
    device_factory: DeviceFactory,
    plugin_scanner: PluginScanner,
    plugin_stats: HashMap<(ChannelId, DevicePath), PluginStatsLog>,
    plugin_stats_since: Instant,
    plugin_reports: HashMap<(ChannelId, DevicePath), PluginStatsReport>,
    plugin_reports_since: Instant,
    stream: StreamControl,
    audio: AudioSettings,
    block_clock: Arc<BlockClock>,
    /// The offline render running or last run (`audio/render`).
    render: Option<RenderHandle>,
}

impl CommandWorker {
    /// Create a worker whose devices run at `device_sample_rate` with buffers of up to
    /// `max_buffer_size` frames. `stream` is running with `audio_request`.
    pub fn new(
        state: Arc<Mutex<EngineState>>,
        status_tx: Sender<EngineStatus>,
        command_tx: Sender<AudioCommand>,
        device_sample_rate: f32,
        max_buffer_size: usize,
        block_clock: Arc<BlockClock>,
        stream: StreamControl,
        audio_request: StreamRequest,
    ) -> Self {
        let process_manager = Arc::new(ProcessManager::new());
        let device_factory = DeviceFactory::new(
            Arc::clone(&process_manager),
            device_sample_rate,
            max_buffer_size,
            status_tx.clone(),
            command_tx,
            block_clock.clone(),
        );

        Self {
            state,
            status_tx,
            max_buffer_size,
            process_manager,
            device_factory,
            plugin_scanner: PluginScanner::new(),
            plugin_stats: HashMap::new(),
            plugin_stats_since: Instant::now(),
            plugin_reports: HashMap::new(),
            plugin_reports_since: Instant::now(),
            stream,
            audio: AudioSettings {
                opened_period: audio_request.period_frames,
                request: audio_request,
                graph: None,
                notice: String::new(),
                mismatch: String::new(),
            },
            block_clock,
            render: None,
        }
    }

    /// Apply commands until every sender has been dropped, servicing devices every
    /// `DEVICE_POLL_INTERVAL` in between.
    pub fn run(mut self, command_rx: Receiver<AudioCommand>) {
        let mut next_poll = Instant::now() + DEVICE_POLL_INTERVAL;
        loop {
            match command_rx.recv_deadline(next_poll) {
                Ok(cmd) => self.handle(cmd),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
            if Instant::now() >= next_poll {
                self.poll_devices();
                next_poll = Instant::now() + DEVICE_POLL_INTERVAL;
            }
        }
    }

    /// Lock the engine state, recovering it if an earlier command panicked while holding it.
    fn lock_state(&self) -> MutexGuard<'_, EngineState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Send a status update to Godot.
    fn send_status(&self, status: EngineStatus) {
        let _ = self.status_tx.send(status);
    }

    /// Run slow commands with the lock released and everything else under the lock.
    fn handle(&mut self, cmd: AudioCommand) {
        match cmd {
            AudioCommand::ScanPlugins { paths } => self.scan_plugins(paths),
            AudioCommand::StartRender(job) => self.start_render(job),
            AudioCommand::CancelRender { job_id } => self.cancel_render(&job_id),
            AudioCommand::AdvertiseBuiltinDevices => self.advertise_builtin_devices(),
            AudioCommand::AddDeviceToChannel {
                channel_id,
                parent_path,
                device_id,
                device_type,
                device_file,
                position,
                active,
                enabled,
            } => self.add_device(
                channel_id,
                parent_path,
                &device_id,
                &device_type,
                &device_file,
                position,
                active,
                enabled,
            ),
            AudioCommand::RemoveDeviceFromChannel {
                channel_id,
                parent_path,
                position,
            } => self.remove_device(channel_id, parent_path, position),
            AudioCommand::ReloadDevice {
                channel_id,
                device_path,
            } => self.reload_device(channel_id, device_path),
            AudioCommand::SetPluginHosting { policy } => self.set_plugin_hosting(policy),
            AudioCommand::SetAudioConfig {
                device,
                sample_rate,
                period_frames,
            } => self.set_audio_config(StreamRequest {
                device,
                sample_rate,
                period_frames,
            }),
            AudioCommand::RequestAudioConfig => self.report_audio_config(),
            AudioCommand::RequestAudioDevices => self.list_audio_devices(),
            AudioCommand::PipeWireGraph(graph) => self.on_pipewire_graph(graph),
            route @ AudioCommand::SetChannelRoute { id: 1, .. } => {
                self.apply_locked(route);
                self.check_master_output();
            }
            AudioCommand::SavePluginState {
                channel_id,
                device_path,
                file_path,
            } => self.save_plugin_state(channel_id, device_path, file_path),
            AudioCommand::LoadPluginState {
                channel_id,
                device_path,
                file_path,
            } => self.load_plugin_state(channel_id, device_path, file_path),
            AudioCommand::ConfigureDeviceData {
                channel_id,
                device_path,
                data_type,
                key,
                value,
            } => self.configure_device_data(channel_id, device_path, &data_type, &key, value),
            AudioCommand::ClearChannelDevices { channel_id } => self.clear_devices(channel_id),
            AudioCommand::RemoveChannel { id } => self.remove_channel(id),
            AudioCommand::ClearProject => self.clear_project(),
            AudioCommand::SetTempoMap(points) => self.set_tempo_map(points),
            AudioCommand::SetTimeSignatureMap(changes) => self.set_time_signature_map(changes),
            AudioCommand::SetDeviceActive {
                channel_id,
                device_path,
                active,
            } => match self.plugin_handle(channel_id, &device_path) {
                Some(handle) => self.set_plugin_active(handle, channel_id, device_path, active),
                None => self.apply_locked(AudioCommand::SetDeviceActive {
                    channel_id,
                    device_path,
                    active,
                }),
            },
            AudioCommand::OpenPluginGui {
                channel_id,
                device_path,
                window_handle,
            } => match self.plugin_handle(channel_id, &device_path) {
                Some(handle) => {
                    self.open_plugin_gui(handle, channel_id, device_path, window_handle)
                }
                None => self.apply_locked(AudioCommand::OpenPluginGui {
                    channel_id,
                    device_path,
                    window_handle,
                }),
            },
            AudioCommand::ClosePluginGui {
                channel_id,
                device_path,
            } => match self.plugin_handle(channel_id, &device_path) {
                Some(handle) => self.close_plugin_gui(handle, channel_id, device_path),
                None => self.apply_locked(AudioCommand::ClosePluginGui {
                    channel_id,
                    device_path,
                }),
            },
            AudioCommand::SetPluginGuiVisible {
                channel_id,
                device_path,
                visible,
            } => match self.plugin_handle(channel_id, &device_path) {
                Some(handle) => {
                    if let Err(e) = handle.set_gui_visible(visible) {
                        warn!(
                            "Failed to {} plugin GUI at channel {} device {}: {}",
                            if visible { "show" } else { "hide" },
                            channel_id,
                            device_path,
                            e
                        );
                    }
                }
                None => warn!(
                    "SetPluginGuiVisible: no subprocess plugin at channel {} device {}",
                    channel_id, device_path
                ),
            },
            AudioCommand::SetPluginGuiSize {
                channel_id,
                device_path,
                width,
                height,
            } => match self.plugin_handle(channel_id, &device_path) {
                Some(handle) => match handle.set_gui_size(width, height) {
                    Ok((width, height)) => self.send_status(EngineStatus::PluginGuiResizeRequest {
                        channel_id,
                        device_path,
                        width,
                        height,
                    }),
                    Err(e) => warn!(
                        "Failed to resize plugin GUI at channel {} device {} to {}x{}: {}",
                        channel_id, device_path, width, height, e
                    ),
                },
                None => warn!(
                    "SetPluginGuiSize: no subprocess plugin at channel {} device {}",
                    channel_id, device_path
                ),
            },
            other => self.apply_locked(other),
        }
    }

    /// Apply a fast command with the state lock held, then send its statuses and drop what it
    /// removed after the lock is released.
    ///
    /// Sending blocks when the status channel is full, and dropping a clip's PCM frees memory.
    /// With the lock held either would make the audio callback miss its `try_lock` and output
    /// silence, so `process_command` only collects them in `CommandEffects`. Statuses go out in
    /// the order the command produced them.
    fn apply_locked(&self, cmd: AudioCommand) {
        let mut effects = CommandEffects::default();
        {
            let mut state = self.lock_state();
            process_command(&mut state, cmd, self.max_buffer_size, &mut effects);
        }
        let CommandEffects { statuses, trash } = effects;
        for status in statuses {
            self.send_status(status);
        }
        drop(trash);
    }
}
