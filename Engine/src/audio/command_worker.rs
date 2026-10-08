//! Command thread: applies `AudioCommand`s to the engine state shared with the audio callback.
//!
//! The audio callback gives up on a buffer if it can't take the state lock quickly, so this
//! worker holds the lock only to read or swap state. Slow work (plugin scans, building and
//! dropping devices, plugin subprocess round-trips) runs with the lock released. This is safe
//! because the worker is the only thread that adds or removes channels and devices.

use crossbeam::channel::{Receiver, RecvTimeoutError, Sender};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tracing::{error, info, warn};

use super::block_clock::BlockClock;
use super::commands::{process_command, AudioCommand, CommandEffects, EngineStatus};
use super::devices::clap_host::subprocess_adapter::{
    PluginBlockStats, PluginIpcHandle, PluginLoad, HUNG_STALL_TIMEOUT,
};
use super::devices::clap_host::{PluginScanner, SubprocessClapAdapter};
use super::devices::sfizz_keys::KeyKind;
use super::devices::{
    container, AudioDevice, DeviceFactory, DevicePath, ParamId, ParamValue, SfizzDevice,
};
use super::ipc::{HostingPolicy, PluginEvent, ProcessManager};
use super::pipewire::GraphInfo;
use super::render::{RenderHandle, RenderJob};
use super::state::EngineState;
use super::stream::{StreamControl, StreamRequest};
use super::tempo_map::TempoMap;
use super::time_signature_map::TimeSignatureMap;
use super::types::{ChannelId, Tick};

mod audio_config;

/// How often the command thread services devices between commands: plugin parameter changes,
/// queued automation writes, plugin crash checks and SFZ parameter lists. This is work the audio
/// callback must not do itself.
const DEVICE_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// How often per-plugin audio problems (dropouts, overflows, MIDI drops) are logged, if any.
const PLUGIN_STATS_LOG_INTERVAL: Duration = Duration::from_secs(10);

/// How often each plugin's processing stats are sent to Godot (`<device addr>/stats`).
const PLUGIN_STATS_REPORT_INTERVAL: Duration = Duration::from_secs(1);

/// A subprocess plugin collected under the state lock for `poll_devices` to service without it.
struct PolledPlugin {
    channel_id: ChannelId,
    device_path: DevicePath,
    handle: PluginIpcHandle,
    load: Arc<PluginLoad>,
    writes: Vec<(ParamId, ParamValue)>,
    /// Parameter changes the plugin made while processing (from its output events).
    output_events: Vec<(ParamId, ParamValue)>,
    stats: PluginBlockStats,
    /// The plugin's saved state is stale and its interval has passed, so ask for a fresh blob.
    save_state_due: bool,
    /// The host left a block unfinished for `HUNG_STALL_TIMEOUT`.
    stalled: bool,
    /// The hosting policy now puts this instance in another host process (Phase 5).
    host_changed: bool,
    /// Activated at a rate other than the engine's: it finished loading while the rate changed.
    rate_stale: bool,
}

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

/// Per-plugin audio problem counts since the last log.
struct PluginStatsLog {
    name: String,
    stats: PluginBlockStats,
}

/// A plugin's stats since the last report to Godot.
#[derive(Default)]
struct PluginStatsReport {
    window: PluginBlockStats,
    /// Deadline misses since the device was first seen.
    total_misses: u64,
    /// Blocks in the last report, so an idle plugin is reported once and then left alone.
    last_blocks: u64,
    /// Seen in this reporting interval; entries of removed devices are dropped.
    seen: bool,
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

    /// Service devices on behalf of the audio callback.
    ///
    /// Under the state lock: collect each ready subprocess plugin's IPC handle, queued
    /// automation writes and audio-thread counters, and any new SFZ parameter lists. With the
    /// lock released: send the writes, drain the events the plugins sent (parameter changes, GUI
    /// resize requests), detect dead subprocesses, and send statuses.
    fn poll_devices(&mut self) {
        let mut plugins: Vec<PolledPlugin> = Vec::new();
        let mut statuses: Vec<EngineStatus> = Vec::new();
        let now = Instant::now();
        {
            let mut state = self.lock_state();
            for (&channel_id, channel) in state.channels.iter_mut() {
                container::visit_devices_mut(&mut channel.devices, &mut |device_path, device| {
                    let any = device.as_any_mut();
                    if let Some(plugin) = any.downcast_mut::<SubprocessClapAdapter>() {
                        let load = plugin.load();
                        if !load.is_ready() {
                            return;
                        }
                        let mut writes = Vec::new();
                        plugin.drain_queued_parameters(&mut writes);
                        let mut output_events = Vec::new();
                        plugin.drain_output_events(&mut output_events);
                        plugins.push(PolledPlugin {
                            channel_id,
                            device_path: *device_path,
                            handle: plugin.ipc_handle(),
                            load,
                            writes,
                            output_events,
                            stats: plugin.take_stats(),
                            save_state_due: plugin.take_state_save_due(),
                            stalled: plugin.is_host_stalled(now),
                            host_changed: plugin.desired_host() != *plugin.host_assignment(),
                            rate_stale: plugin.needs_reactivation(),
                        });
                    } else if let Some(sfizz) = any.downcast_mut::<SfizzDevice>() {
                        collect_sfizz_parameters(channel_id, *device_path, sfizz, &mut statuses);
                        collect_sfizz_key_info(channel_id, *device_path, sfizz, &mut statuses);
                    }
                });
            }
        }

        let mut reported: Vec<(ChannelId, DevicePath, u32, f32)> = Vec::new();
        let mut events = Vec::new();
        for plugin in &plugins {
            if !plugin.handle.is_alive() {
                self.mark_plugin_crashed(plugin);
                continue;
            }
            // A host that stopped answering a request, or that stopped finishing blocks, is hung:
            // kill it. The next tick sees it dead and marks the device crashed.
            if plugin.handle.is_hung() {
                warn!(
                    "Plugin host for {} (channel {} device {}) stopped responding; killing it",
                    plugin.handle.device_name(),
                    plugin.channel_id,
                    plugin.device_path
                );
                plugin.handle.kill_host();
                continue;
            }
            // An offline render gives a block more time than the stall timeout and fails on a
            // plugin that misses it, so a slow offline block isn't a hang.
            if plugin.stalled && !plugin.handle.is_debugging() && !self.block_clock.is_offline() {
                warn!(
                    "Plugin {} (channel {} device {}) hasn't finished a block in {:?}; killing its host",
                    plugin.handle.device_name(),
                    plugin.channel_id,
                    plugin.device_path,
                    HUNG_STALL_TIMEOUT
                );
                plugin.handle.kill_host();
                continue;
            }
            if plugin.host_changed {
                // Moving respawns the instance, so its queued writes and events go with the
                // state it saves on the way out.
                self.move_plugin(plugin);
                continue;
            }
            if plugin.rate_stale {
                self.reactivate_plugin(plugin.channel_id, plugin.device_path, &plugin.handle);
            }
            if plugin.save_state_due {
                match plugin.handle.save_state() {
                    Ok(state) => {
                        let len = state.len();
                        self.with_plugin(plugin.channel_id, &plugin.device_path, |plugin| {
                            plugin.set_saved_state(state)
                        });
                        info!(
                            "Refreshed saved state of plugin {} ({} bytes)",
                            plugin.handle.device_name(),
                            len
                        );
                    }
                    Err(e) => warn!(
                        "Could not refresh the saved state of plugin {}: {}",
                        plugin.handle.device_name(),
                        e
                    ),
                }
            }
            if !plugin.writes.is_empty() {
                plugin.handle.set_parameters(&plugin.writes);
            }
            for (param_id, value) in plugin.output_events.iter().copied() {
                reported.push((plugin.channel_id, plugin.device_path, param_id, value));
                statuses.push(EngineStatus::PluginParameterValueChanged {
                    channel_id: plugin.channel_id,
                    device_path: plugin.device_path,
                    param_id,
                    value,
                });
            }
            events.clear();
            plugin.handle.poll_events(&mut events);
            for event in events.drain(..) {
                match event {
                    PluginEvent::ParameterValueChanged { param_id, value } => {
                        reported.push((plugin.channel_id, plugin.device_path, param_id, value));
                        statuses.push(EngineStatus::PluginParameterValueChanged {
                            channel_id: plugin.channel_id,
                            device_path: plugin.device_path,
                            param_id,
                            value,
                        });
                    }
                    PluginEvent::GuiResizeRequest { width, height } => {
                        statuses.push(EngineStatus::PluginGuiResizeRequest {
                            channel_id: plugin.channel_id,
                            device_path: plugin.device_path,
                            width,
                            height,
                        });
                    }
                    PluginEvent::StateDirty => {
                        self.with_plugin(plugin.channel_id, &plugin.device_path, |plugin| {
                            plugin.set_state_dirty()
                        });
                    }
                }
            }
            if !plugin.output_events.is_empty() {
                // The plugin changed its own parameter values, so its saved state is stale.
                self.with_plugin(plugin.channel_id, &plugin.device_path, |plugin| {
                    plugin.set_state_dirty()
                });
            }
            self.record_plugin_stats(plugin);
        }

        if !reported.is_empty() {
            let mut state = self.lock_state();
            for (channel_id, device_path, param_id, value) in reported {
                let plugin = state
                    .channels
                    .get_mut(&channel_id)
                    .and_then(|channel| channel.device_at_path_mut(&device_path))
                    .and_then(|device| device.as_any_mut().downcast_mut::<SubprocessClapAdapter>());
                if let Some(plugin) = plugin {
                    plugin.cache_parameter_value(param_id, value);
                }
            }
        }

        for status in statuses {
            self.send_status(status);
        }
        self.log_plugin_stats();
        self.report_plugin_stats();
    }

    /// The plugin's host process has exited or is hung: pass audio through from now on and tell
    /// Godot why, with the host's stderr tail. The device UI offers a Reload.
    fn mark_plugin_crashed(&self, plugin: &PolledPlugin) {
        let crash = plugin.handle.crash_info();
        let reason = crash
            .as_ref()
            .map(|crash| crash.describe())
            .unwrap_or_else(|| "host process stopped responding".to_string());
        let stderr = crash
            .as_ref()
            .map(|crash| crash.stderr_tail.join("\n"))
            .unwrap_or_default();
        let pid = crash
            .as_ref()
            .map(|crash| crash.pid)
            .or_else(|| plugin.handle.host_pid())
            .unwrap_or(0);
        let log_path = crash
            .as_ref()
            .and_then(|crash| crash.log_path.as_ref())
            .map(|path| path.display().to_string())
            .unwrap_or_default();

        error!(
            "Plugin {} (channel {} device {}) crashed: {} (host {} pid {}). Bypassing it; Reload restores it.",
            plugin.handle.device_name(),
            plugin.channel_id,
            plugin.device_path,
            reason,
            crash.as_ref().map(|crash| crash.host_key.as_str()).unwrap_or("unknown"),
            pid
        );
        if !stderr.is_empty() {
            warn!("Last stderr from plugin host {}: {}", pid, stderr);
        }
        if !log_path.is_empty() {
            info!("Full log of plugin host {}: {}", pid, log_path);
        }

        plugin.load.set_crashed(reason.clone());
        self.send_status(EngineStatus::DeviceLoadingStateChanged {
            channel_id: plugin.channel_id,
            device_path: plugin.device_path,
            state: format!("crashed:{}", reason),
        });
        self.send_status(EngineStatus::DeviceCrashed {
            channel_id: plugin.channel_id,
            device_path: plugin.device_path,
            reason,
            stderr,
            pid,
            log_path,
        });
    }

    /// Respawn a crashed plugin's host and restore its state on a background thread.
    ///
    /// A crash takes down every instance in the host, so every device that was in the same host
    /// process is reloaded with it: one Reload brings the whole host back (Phase 5).
    fn reload_device(&self, channel_id: ChannelId, device_path: DevicePath) {
        let state = self.with_plugin(channel_id, &device_path, |plugin| {
            let load = plugin.load();
            (load.is_crashed() || load.is_failed(), load.host_pid())
        });
        let host_pid = match state {
            None => {
                warn!(
                    "Reload requested for channel {} device {}, which is not a subprocess plugin",
                    channel_id, device_path
                );
                return;
            }
            Some((false, _)) => {
                warn!(
                    "Reload requested for channel {} device {}, but it hasn't crashed",
                    channel_id, device_path
                );
                return;
            }
            Some((true, pid)) => pid,
        };

        let mut requests = Vec::new();
        {
            let mut state = self.lock_state();
            for (&id, channel) in state.channels.iter_mut() {
                container::visit_devices_mut(&mut channel.devices, &mut |path, device| {
                    let Some(plugin) = device.as_any_mut().downcast_mut::<SubprocessClapAdapter>()
                    else {
                        return;
                    };
                    let load = plugin.load();
                    let requested = id == channel_id && *path == device_path;
                    // Pid 0: the plugin never finished loading, so it shared no host.
                    let same_host =
                        host_pid != 0 && load.is_crashed() && load.host_pid() == host_pid;
                    if requested || same_host {
                        requests.push((id, *path, plugin.begin_reload()));
                    }
                });
            }
        }
        for (id, path, request) in requests {
            info!(
                "Reloading plugin at channel {} device {} (host pid {} crashed)",
                id, path, host_pid
            );
            request.spawn();
        }
    }

    /// Replace the hosting policy and move every loaded plugin whose host changed.
    fn set_plugin_hosting(&mut self, policy: HostingPolicy) {
        self.process_manager.set_hosting_policy(policy);
        // The next tick compares every ready plugin with the new policy and moves it; run it now
        // rather than up to one interval later.
        self.poll_devices();
    }

    /// Move a plugin to the host process the hosting policy now picks: save its state, close its
    /// GUI, then respawn it there through the reload path, which restores the state (Phase 5).
    /// Audio passes through the plugin until it is ready in its new host.
    fn move_plugin(&self, plugin: &PolledPlugin) {
        let (channel_id, device_path) = (plugin.channel_id, plugin.device_path);
        let gui_open = self
            .with_plugin(channel_id, &device_path, |plugin| plugin.is_gui_open())
            .unwrap_or(false);
        if gui_open {
            if let Err(e) = plugin.handle.close_gui() {
                warn!(
                    "Failed to close the GUI of {} before moving it: {}",
                    plugin.handle.device_name(),
                    e
                );
            }
            self.send_status(EngineStatus::PluginGuiClosed {
                channel_id,
                device_path,
            });
        }

        // Without a state extension the reload re-sends the cached parameter values instead.
        match plugin.handle.save_state() {
            Ok(state) => {
                self.with_plugin(channel_id, &device_path, |plugin| {
                    plugin.set_saved_state(state)
                });
            }
            Err(e) => info!(
                "Moving {} without a state blob ({}); its parameter values are re-sent",
                plugin.handle.device_name(),
                e
            ),
        }

        let request = self.with_plugin(channel_id, &device_path, |plugin| {
            let from = plugin.host_assignment().key.clone();
            let to = plugin.desired_host();
            // The policy may have changed back while the state was saved.
            if to == *plugin.host_assignment() || !plugin.load().is_ready() {
                return None;
            }
            Some((from, to.key, plugin.begin_reload()))
        });
        if let Some(Some((from, to, request))) = request {
            info!(
                "Moving plugin {} (channel {} device {}) from host {} to host {}",
                plugin.handle.device_name(),
                channel_id,
                device_path,
                from,
                to
            );
            request.spawn();
        }
    }

    /// Ask a plugin for its state blob, write it to `file_path` and report the size (project
    /// save path). The blob travels as a file because it rarely fits one OSC datagram.
    fn save_plugin_state(&self, channel_id: ChannelId, device_path: DevicePath, file_path: String) {
        let Some(handle) = self.plugin_handle(channel_id, &device_path) else {
            // Not a subprocess plugin: the locked path reports it has no state.
            self.apply_locked(AudioCommand::SavePluginState {
                channel_id,
                device_path,
                file_path,
            });
            return;
        };

        let size = match handle.save_state() {
            Ok(state) => match std::fs::write(&file_path, &state) {
                Ok(()) => {
                    info!(
                        "Saved {} bytes of plugin state (channel {} device {}) to {}",
                        state.len(),
                        channel_id,
                        device_path,
                        file_path
                    );
                    let size = state.len() as i64;
                    self.with_plugin(channel_id, &device_path, |plugin| {
                        plugin.set_saved_state(state)
                    });
                    size
                }
                Err(e) => {
                    warn!(
                        "Failed to write plugin state (channel {} device {}) to {}: {}",
                        channel_id, device_path, file_path, e
                    );
                    -1
                }
            },
            Err(e) => {
                warn!(
                    "Failed to save plugin state (channel {} device {}): {}",
                    channel_id, device_path, e
                );
                -1
            }
        };
        self.send_status(EngineStatus::PluginStateSaved {
            channel_id,
            device_path,
            file_path,
            size,
        });
    }

    /// Hand a state blob read from `file_path` back to a plugin (project load path).
    fn load_plugin_state(&self, channel_id: ChannelId, device_path: DevicePath, file_path: String) {
        let Some(handle) = self.plugin_handle(channel_id, &device_path) else {
            self.apply_locked(AudioCommand::LoadPluginState {
                channel_id,
                device_path,
                file_path,
            });
            return;
        };

        let state = match std::fs::read(&file_path) {
            Ok(state) => state,
            Err(e) => {
                warn!(
                    "Could not read plugin state for channel {} device {} from {}: {}",
                    channel_id, device_path, file_path, e
                );
                return;
            }
        };
        let len = state.len();
        match handle.load_state(state.clone()) {
            Ok(()) => {
                // Keep it as the saved state too, so a crash before the next refresh restores
                // what the project loaded rather than the plugin's defaults.
                self.with_plugin(channel_id, &device_path, |plugin| {
                    plugin.set_saved_state(state);
                    plugin.set_state_dirty();
                });
                info!(
                    "Restored {} bytes of plugin state (channel {} device {})",
                    len, channel_id, device_path
                );
            }
            Err(e) => warn!(
                "Failed to load plugin state (channel {} device {}): {}",
                channel_id, device_path, e
            ),
        }
    }

    /// Add a plugin's audio-thread counters to the running totals for the next log and the next
    /// report to Godot.
    fn record_plugin_stats(&mut self, plugin: &PolledPlugin) {
        let s = plugin.stats;
        let report = self
            .plugin_reports
            .entry((plugin.channel_id, plugin.device_path))
            .or_default();
        report.window.merge(&s);
        report.total_misses += s.deadline_misses;
        report.seen = true;

        // Keep the whole window, so the log can show process times next to the misses.
        let entry = self
            .plugin_stats
            .entry((plugin.channel_id, plugin.device_path))
            .or_insert_with(|| PluginStatsLog {
                name: plugin.handle.device_name().to_string(),
                stats: PluginBlockStats::default(),
            });
        entry.stats.merge(&s);
    }

    /// Send each plugin's stats to Godot every `PLUGIN_STATS_REPORT_INTERVAL`. A plugin that
    /// processed nothing (asleep, or the transport stopped and it has no tail) is reported once
    /// with zeros and then skipped until it processes again.
    fn report_plugin_stats(&mut self) {
        if self.plugin_reports_since.elapsed() < PLUGIN_STATS_REPORT_INTERVAL {
            return;
        }
        self.plugin_reports_since = Instant::now();
        self.plugin_reports.retain(|_, report| report.seen);
        let mut statuses = Vec::new();
        for (&(channel_id, device_path), report) in self.plugin_reports.iter_mut() {
            let window = std::mem::take(&mut report.window);
            report.seen = false;
            let blocks = window.blocks();
            if blocks == 0 && report.last_blocks == 0 {
                continue;
            }
            report.last_blocks = blocks;
            let process_avg_us = if window.blocks_done == 0 {
                0.0
            } else {
                window.process_ns_total as f32 / window.blocks_done as f32 / 1000.0
            };
            statuses.push(EngineStatus::PluginStats {
                channel_id,
                device_path,
                load_avg: window.load_avg(),
                load_peak: window.load_peak,
                process_avg_us,
                process_max_us: window.process_ns_max as f32 / 1000.0,
                blocks,
                deadline_misses: window.deadline_misses,
                total_misses: report.total_misses,
                struggling: window.is_struggling(),
            });
        }
        for status in statuses {
            self.send_status(status);
        }
    }

    /// Log and reset per-plugin problem counts every `PLUGIN_STATS_LOG_INTERVAL`.
    fn log_plugin_stats(&mut self) {
        let elapsed = self.plugin_stats_since.elapsed();
        if elapsed < PLUGIN_STATS_LOG_INTERVAL {
            return;
        }
        for ((channel_id, device_path), entry) in self.plugin_stats.drain() {
            let s = entry.stats;
            if s.deadline_misses == 0 && s.event_drops == 0 {
                continue;
            }
            warn!(
                "Plugin {} (channel {} device {}) in the last {:.0}s: {} of {} blocks missed the processing deadline ({} dropped because the previous block was still running), {} input events dropped; process avg {:.2} ms, max {:.2} ms, load peak {:.0}%; longest engine wait {:.2} ms",
                entry.name,
                channel_id,
                device_path,
                elapsed.as_secs_f32(),
                s.deadline_misses,
                s.blocks(),
                s.late_drops,
                s.event_drops,
                s.process_ns_total as f64 / s.blocks_done.max(1) as f64 / 1e6,
                s.process_ns_max as f64 / 1e6,
                s.load_peak * 100.0,
                s.wait_ns_max as f64 / 1e6,
            );
        }
        self.plugin_stats_since = Instant::now();
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

    /// Start an offline render on its own thread. Only one runs at a time; another job fails
    /// at once.
    fn start_render(&mut self, job: RenderJob) {
        if let Some(running) = self.render.as_ref().filter(|r| !r.is_finished()) {
            self.send_status(EngineStatus::RenderFailed {
                job_id: job.job_id,
                error: format!("render {} is still running", running.job_id()),
            });
            return;
        }
        let job_id = job.job_id.clone();
        match RenderHandle::spawn(job, self.state.clone(), self.status_tx.clone()) {
            Ok(handle) => self.render = Some(handle),
            Err(e) => self.send_status(EngineStatus::RenderFailed {
                job_id,
                error: format!("couldn't start the render thread: {}", e),
            }),
        }
    }

    /// Cancel the running render if it is `job_id`.
    fn cancel_render(&self, job_id: &str) {
        match self.render.as_ref().filter(|r| !r.is_finished()) {
            Some(running) if running.job_id() == job_id => running.cancel(),
            _ => warn!("Cancel for render {}, which isn't running", job_id),
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

    /// Scan for CLAP plugins and report each one to Godot.
    fn scan_plugins(&mut self, paths: Vec<PathBuf>) {
        info!("Starting plugin scan...");
        self.plugin_scanner.set_paths(paths);
        let count = match self.plugin_scanner.scan() {
            Ok(count) => count,
            Err(e) => {
                warn!("Plugin scan failed: {}", e);
                return;
            }
        };
        info!("Plugin scan complete: {} plugins found", count);

        // Godot drains its OSC socket once per frame into a 64 KB queue, and a full scan is
        // far more than that. Send in batches with a pause (about one frame) in between so
        // the tail, including /plugin/scan_complete, isn't dropped.
        const BATCH: usize = 32;
        const BATCH_PAUSE: std::time::Duration = std::time::Duration::from_millis(20);

        for (i, plugin) in self.plugin_scanner.all_plugins().enumerate() {
            if i > 0 && i % BATCH == 0 {
                std::thread::sleep(BATCH_PAUSE);
            }
            let category = plugin.category.as_str().to_string();

            self.send_status(EngineStatus::PluginInfo {
                id: plugin.id.clone(),
                name: plugin.name.clone(),
                vendor: plugin.vendor.clone(),
                version: plugin.version.clone(),
                category,
                description: plugin.description.clone(),
                path: plugin.path.to_string_lossy().to_string(),
                features: plugin.features.clone(),
            });
        }

        std::thread::sleep(BATCH_PAUSE);
        self.send_status(EngineStatus::PluginScanComplete { count });
    }

    /// Describe the built-in devices to Godot.
    fn advertise_builtin_devices(&self) {
        info!("Advertising builtin devices...");
        let device_infos = self.device_factory.builtin_device_infos();
        let count = device_infos.len();
        for device_info in device_infos {
            self.send_status(device_info);
        }
        for kind_info in crate::audio::commands::modulator_kind_infos() {
            self.send_status(kind_info);
        }
        info!("Advertised {} builtin devices", count);
        self.send_status(EngineStatus::BuiltinDevicesComplete { count });
    }

    /// Build a device with the lock released, then insert it into the parent list.
    #[allow(clippy::too_many_arguments)]
    fn add_device(
        &mut self,
        channel_id: ChannelId,
        parent_path: DevicePath,
        device_id: &str,
        device_type: &str,
        device_file: &str,
        position: i32,
        active: bool,
        enabled: bool,
    ) {
        if !parent_path.can_join() {
            warn!(
                "Cannot add device {} below channel {} path {}: nesting is too deep",
                device_id, channel_id, parent_path
            );
            return;
        }
        let child_count = {
            let state = self.lock_state();
            let Some(channel) = state.channels.get(&channel_id) else {
                warn!("Channel {} not found for add device", channel_id);
                return;
            };
            if parent_path.is_empty() {
                channel.devices.len()
            } else {
                match channel
                    .device_at_path(&parent_path)
                    .and_then(|d| d.as_container())
                {
                    Some(container) => container.child_count(),
                    None => {
                        warn!(
                            "No container at channel {} path {} for add device",
                            channel_id, parent_path
                        );
                        return;
                    }
                }
            }
        };

        let insert_pos = if position < 0 {
            child_count
        } else {
            (position as usize).min(child_count)
        };
        let device_path = parent_path.join(insert_pos);

        // The vendor picks the host process in "By vendor" hosting.
        let vendor = if device_type == "clap" {
            self.plugin_scanner
                .vendor_of(device_id, Path::new(device_file))
                .unwrap_or_else(|| "Unknown".to_string())
        } else {
            String::new()
        };

        let Some(mut device) = self.device_factory.create(
            device_type,
            device_id,
            device_file,
            &vendor,
            channel_id,
            &device_path,
        ) else {
            return;
        };
        device.set_enabled(enabled);

        let mut state = self.lock_state();
        let Some(channel) = state.channels.get_mut(&channel_id) else {
            warn!(
                "Channel {} was removed while device {} was being created",
                channel_id, device_id
            );
            return;
        };
        match super::devices::container::insert_device(
            &mut channel.devices,
            &parent_path,
            insert_pos,
            device,
        ) {
            Ok(path) => info!(
                "Device {} added to channel {} at {} [active={}, enabled={}]",
                device_id, channel_id, path, active, enabled
            ),
            Err(e) => warn!("{}", e),
        }
    }

    /// Detach a device under the lock and drop it afterwards: dropping a CLAP plugin closes its
    /// GUI and shuts down its subprocess.
    fn remove_device(&self, channel_id: ChannelId, parent_path: DevicePath, position: usize) {
        if !parent_path.can_join() {
            warn!(
                "Invalid device parent path {} for channel {}",
                parent_path, channel_id
            );
            return;
        }
        let path = parent_path.join(position);
        let removed = {
            let mut state = self.lock_state();
            let Some(channel) = state.channels.get_mut(&channel_id) else {
                warn!("Channel {} not found for remove device", channel_id);
                return;
            };
            channel.release_note_effect_at(&path);
            super::devices::container::remove_device(&mut channel.devices, &path)
        };
        if removed.is_none() {
            warn!("Invalid device path {} for channel {}", path, channel_id);
            return;
        }
        drop(removed);
        info!("Device removed from channel {} at {}", channel_id, path);
    }

    /// Set a device data stream option. An option that needs new buffers (the EQ analyser's FFT
    /// size) builds them with the lock released and swaps them in; the old ones are dropped
    /// after the lock is released again.
    fn configure_device_data(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        data_type: &str,
        key: &str,
        value: f32,
    ) {
        let build = {
            let mut state = self.lock_state();
            let Some(device) = state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
            else {
                warn!(
                    "Device not found at channel {} path {} for configure device data",
                    channel_id, device_path
                );
                return;
            };
            match device.configure_data(data_type, key, value) {
                Ok(build) => build,
                Err(e) => {
                    warn!(
                        "Failed to set '{}' of '{}' on channel {} device {}: {}",
                        key, data_type, channel_id, device_path, e
                    );
                    return;
                }
            }
        };
        let Some(build) = build else {
            return;
        };
        let built = build();
        let replaced = {
            let mut state = self.lock_state();
            match state
                .channels
                .get_mut(&channel_id)
                .and_then(|channel| channel.device_at_path_mut(&device_path))
            {
                Some(device) => device.apply_data_build(built),
                None => Some(built),
            }
        };
        drop(replaced);
    }

    /// Detach a channel's whole device chain under the lock and drop it afterwards.
    fn clear_devices(&self, channel_id: ChannelId) {
        let removed = {
            let mut state = self.lock_state();
            let Some(channel) = state.channels.get_mut(&channel_id) else {
                warn!("Channel {} not found for clear devices", channel_id);
                return;
            };
            std::mem::take(&mut channel.devices)
        };
        drop(removed);
        info!("All devices cleared from channel {}", channel_id);
    }

    /// Detach a channel under the lock and drop it, with its devices, afterwards.
    fn remove_channel(&self, id: ChannelId) {
        let (removed, remaining) = {
            let mut state = self.lock_state();
            let removed = state.channels.remove(&id);
            (removed, state.channels.len())
        };
        match removed {
            Some(channel) => {
                drop(channel);
                info!("Channel {} removed [total channels: {}]", id, remaining);
            }
            None => warn!("Cannot remove channel {}: not found", id),
        }
    }

    /// Build a tempo map off the lock, swap it in, and drop the old one after unlocking.
    fn set_tempo_map(&self, points: Vec<(Tick, f32)>) {
        let map = TempoMap::from_points(points);
        let count = map.points().len();
        let old = std::mem::replace(&mut self.lock_state().tempo_map, map);
        drop(old);
        info!("Tempo map set: {} points", count);
    }

    /// Build a time signature map off the lock, swap it in, and drop the old one after unlocking.
    fn set_time_signature_map(&self, changes: Vec<(u32, u16, u16)>) {
        let map = TimeSignatureMap::from_changes(changes);
        let count = map.changes().len();
        let old = std::mem::replace(&mut self.lock_state().time_signature_map, map);
        drop(old);
        info!("Time signature map set: {} changes", count);
    }

    /// Swap out all channels, tracks and clips under the lock and drop them afterwards.
    fn clear_project(&self) {
        let removed = {
            let mut state = self.lock_state();
            state.set_current_tick(0);
            state.set_fractional_tick_accumulator(0.0);
            let _ = state.take_playhead_midi_dispatch();
            state.loop_region = None;
            (
                std::mem::take(&mut state.channels),
                std::mem::take(&mut state.tracks),
                std::mem::take(&mut state.clips),
                std::mem::take(&mut state.tempo_map),
                std::mem::take(&mut state.time_signature_map),
            )
        };
        drop(removed);
        {
            let mut state = self.lock_state();
            state.ensure_master_channel(self.max_buffer_size);
        }
        info!("Project cleared");
    }

    /// Get an IPC handle for the subprocess CLAP plugin at a path, or None if the device
    /// doesn't exist or isn't one.
    fn plugin_handle(
        &self,
        channel_id: ChannelId,
        device_path: &DevicePath,
    ) -> Option<PluginIpcHandle> {
        self.with_plugin(channel_id, device_path, |plugin| plugin.ipc_handle())
    }

    /// Run `f` under the lock on the subprocess CLAP plugin at a path, if there is one.
    fn with_plugin<R>(
        &self,
        channel_id: ChannelId,
        device_path: &DevicePath,
        f: impl FnOnce(&mut SubprocessClapAdapter) -> R,
    ) -> Option<R> {
        let mut state = self.lock_state();
        let device = state
            .channels
            .get_mut(&channel_id)?
            .device_at_path_mut(device_path)?;
        device
            .as_any_mut()
            .downcast_mut::<SubprocessClapAdapter>()
            .map(f)
    }

    /// Activate or deactivate a subprocess plugin with the lock released.
    fn set_plugin_active(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_path: DevicePath,
        active: bool,
    ) {
        let is_active = self.with_plugin(channel_id, &device_path, |plugin| plugin.is_active());
        if is_active != Some(!active) {
            return;
        }

        let latency = if active {
            match handle.activate() {
                Ok(latency) => latency,
                Err(e) => {
                    warn!(
                        "Failed to activate device at channel {} path {}: {}",
                        channel_id, device_path, e
                    );
                    return;
                }
            }
        } else {
            if let Err(e) = handle.deactivate() {
                warn!(
                    "Failed to deactivate device at channel {} path {}: {}",
                    channel_id, device_path, e
                );
                return;
            }
            0
        };

        self.with_plugin(channel_id, &device_path, |plugin| {
            plugin.set_active_state(active, latency)
        });
        info!(
            "Device {}: channel={} device={}",
            if active { "activated" } else { "deactivated" },
            channel_id,
            device_path
        );
        self.send_status(EngineStatus::DeviceActiveChanged {
            channel_id,
            device_path,
            active,
        });
    }

    /// Open a subprocess plugin's GUI with the lock released, then report its size so the host
    /// window is sized and Godot can lay it out. An already-open GUI reports its current state.
    fn open_plugin_gui(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_path: DevicePath,
        window_handle: Option<u64>,
    ) {
        let gui = match handle.open_gui(window_handle) {
            Ok(gui) => gui,
            Err(e) => {
                warn!(
                    "Failed to open subprocess plugin GUI at channel {} device {}: {}",
                    channel_id, device_path, e
                );
                return;
            }
        };
        self.with_plugin(channel_id, &device_path, |plugin| plugin.set_gui_open(true));
        info!(
            "Opened GUI for subprocess plugin at channel {} device {} (window_handle: {:?}, size: {}x{}, resizable: {}, floating: {})",
            channel_id, device_path, window_handle, gui.width, gui.height, gui.resizable, gui.floating
        );

        self.send_status(EngineStatus::PluginGuiOpened {
            channel_id,
            device_path,
            width: gui.width,
            height: gui.height,
            resizable: gui.resizable,
            floating: gui.floating,
        });
    }

    /// Close a subprocess plugin's GUI with the lock released, then tell Godot to destroy its
    /// window.
    fn close_plugin_gui(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_path: DevicePath,
    ) {
        let was_open = self
            .with_plugin(channel_id, &device_path, |plugin| plugin.is_gui_open())
            .unwrap_or(false);

        if was_open {
            let result = handle.close_gui();
            self.with_plugin(channel_id, &device_path, |plugin| {
                plugin.set_gui_open(false)
            });
            if let Err(e) = result {
                warn!(
                    "Failed to close subprocess plugin GUI at channel {} device {}: {}",
                    channel_id, device_path, e
                );
                return;
            }
        }

        info!(
            "Closed GUI for subprocess plugin at channel {} device {}",
            channel_id, device_path
        );
        self.send_status(EngineStatus::PluginGuiClosed {
            channel_id,
            device_path,
        });
    }
}

/// Queue the key labels and keyswitches an SFZ declared when it loaded. Sent even when empty.
fn collect_sfizz_key_info(
    channel_id: ChannelId,
    device_path: DevicePath,
    sfizz: &mut SfizzDevice,
    statuses: &mut Vec<EngineStatus>,
) {
    if !sfizz.take_key_info_changed() {
        return;
    }
    let keys = sfizz
        .key_info()
        .into_iter()
        .map(|info| (info.key, info.kind == KeyKind::Keyswitch, info.label))
        .collect();
    statuses.push(EngineStatus::SfzKeyInfo {
        channel_id,
        device_path,
        keys,
        ranges: sfizz.playable_ranges(),
    });
}

/// Queue a status pair describing an SFZ device's parameters when its instrument changed them.
fn collect_sfizz_parameters(
    channel_id: ChannelId,
    device_path: DevicePath,
    sfizz: &mut SfizzDevice,
    statuses: &mut Vec<EngineStatus>,
) {
    if !sfizz.take_parameters_changed() {
        return;
    }
    let params = sfizz.parameters();
    if params.is_empty() {
        return;
    }
    statuses.push(EngineStatus::PluginParameterCount {
        channel_id,
        device_path,
        count: params.len(),
    });
    for param in params.iter() {
        statuses.push(EngineStatus::PluginParameterInfo {
            channel_id,
            device_path,
            param_id: param.id,
            name: param.name.clone(),
            min: param.min,
            max: param.max,
            default: param.default,
            group: sfizz.parameter_group(param.id).to_string(),
            param_type: param.param_type,
            is_hidden: false,
            is_read_only: false,
            is_bypass: false,
            is_modulatable: param.is_modulatable,
            module: String::new(),
            enum_values: param.enum_values.clone(),
            unit: param.unit.clone(),
            display: param.display.clone(),
        });
    }
}
