//! Command thread: applies `AudioCommand`s to the engine state shared with the audio callback.
//!
//! The audio callback gives up on a buffer if it can't take the state lock quickly, so this
//! worker holds the lock only to read or swap state. Slow work (plugin scans, building and
//! dropping devices, plugin subprocess round-trips) runs with the lock released. This is safe
//! because the worker is the only thread that adds or removes channels and devices.

use crossbeam::channel::{Receiver, RecvTimeoutError, Sender};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tracing::{error, info, warn};

use super::block_clock::BlockClock;
use super::commands::{process_command, AudioCommand, EngineState, EngineStatus};
use super::devices::clap_host::subprocess_adapter::{
    PluginBlockStats, PluginIpcHandle, PluginLoad, HUNG_STALL_TIMEOUT,
};
use super::devices::clap_host::{PluginScanner, SubprocessClapAdapter};
use super::devices::{
    container, AudioDevice, DeviceCategory, DeviceFactory, DevicePath, ParamId, ParamValue,
    SfizzDevice,
};
use super::ipc::{PluginEvent, ProcessManager};
use super::types::ChannelId;
use base64::Engine as _;

/// How often the command thread services devices between commands: plugin parameter changes,
/// queued automation writes, plugin crash checks and SFZ parameter lists. This is work the audio
/// callback must not do itself.
const DEVICE_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// How often per-plugin audio problems (dropouts, overflows, MIDI drops) are logged, if any.
const PLUGIN_STATS_LOG_INTERVAL: Duration = Duration::from_secs(10);

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
}

/// Per-plugin audio problem counts since the last log.
struct PluginStatsLog {
    name: String,
    stats: PluginBlockStats,
}

/// Owns the command thread's resources and applies commands to the shared engine state.
pub struct CommandWorker {
    state: Arc<Mutex<EngineState>>,
    status_tx: Sender<EngineStatus>,
    max_buffer_size: usize,
    device_factory: DeviceFactory,
    plugin_scanner: PluginScanner,
    plugin_stats: HashMap<(ChannelId, DevicePath), PluginStatsLog>,
    plugin_stats_since: Instant,
}

impl CommandWorker {
    /// Create a worker whose devices run at `device_sample_rate` with buffers of up to
    /// `max_buffer_size` frames.
    pub fn new(
        state: Arc<Mutex<EngineState>>,
        status_tx: Sender<EngineStatus>,
        command_tx: Sender<AudioCommand>,
        device_sample_rate: f32,
        max_buffer_size: usize,
        block_clock: Arc<BlockClock>,
    ) -> Self {
        let process_manager = Arc::new(ProcessManager::new());
        let device_factory = DeviceFactory::new(
            process_manager,
            device_sample_rate,
            max_buffer_size,
            status_tx.clone(),
            command_tx,
            block_clock,
        );

        Self {
            state,
            status_tx,
            max_buffer_size,
            device_factory,
            plugin_scanner: PluginScanner::new(),
            plugin_stats: HashMap::new(),
            plugin_stats_since: Instant::now(),
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
                        });
                    } else if let Some(sfizz) = any.downcast_mut::<SfizzDevice>() {
                        collect_sfizz_parameters(channel_id, *device_path, sfizz, &mut statuses);
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
            if plugin.stalled {
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
        });
    }

    /// Respawn a crashed plugin's host and restore its state on a background thread.
    fn reload_device(&self, channel_id: ChannelId, device_path: DevicePath) {
        let state = self.with_plugin(channel_id, &device_path, |plugin| {
            let load = plugin.load();
            load.is_crashed() || load.is_failed()
        });
        match state {
            None => warn!(
                "Reload requested for channel {} device {}, which is not a subprocess plugin",
                channel_id, device_path
            ),
            Some(false) => warn!(
                "Reload requested for channel {} device {}, but it hasn't crashed",
                channel_id, device_path
            ),
            Some(true) => {
                let request =
                    self.with_plugin(channel_id, &device_path, |plugin| plugin.begin_reload());
                if let Some(request) = request {
                    info!(
                        "Reloading plugin at channel {} device {}",
                        channel_id, device_path
                    );
                    request.spawn();
                }
            }
        }
    }

    /// Ask a plugin for its state blob and report it (project save path).
    fn save_plugin_state(&self, channel_id: ChannelId, device_path: DevicePath) {
        let Some(handle) = self.plugin_handle(channel_id, &device_path) else {
            // Not a subprocess plugin: keep the old locked behavior (logs and reports empty).
            self.apply_locked(AudioCommand::SavePluginState {
                channel_id,
                device_path,
            });
            return;
        };

        match handle.save_state() {
            Ok(state) => {
                let len = state.len();
                self.with_plugin(channel_id, &device_path, |plugin| {
                    plugin.set_saved_state(state.clone())
                });
                self.send_status(EngineStatus::PluginStateSaved {
                    channel_id,
                    device_path,
                    state_base64: base64::engine::general_purpose::STANDARD.encode(&state),
                });
                info!(
                    "Saved {} bytes of plugin state (channel {} device {})",
                    len, channel_id, device_path
                );
            }
            Err(e) => warn!(
                "Failed to save plugin state (channel {} device {}): {}",
                channel_id, device_path, e
            ),
        }
    }

    /// Hand a base64 state blob back to a plugin (project load path).
    fn load_plugin_state(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        state_base64: &str,
    ) {
        let Some(handle) = self.plugin_handle(channel_id, &device_path) else {
            self.apply_locked(AudioCommand::LoadPluginState {
                channel_id,
                device_path,
                state_base64: state_base64.to_string(),
            });
            return;
        };

        let state = match base64::engine::general_purpose::STANDARD.decode(state_base64) {
            Ok(state) => state,
            Err(e) => {
                warn!(
                    "Invalid plugin state for channel {} device {}: {}",
                    channel_id, device_path, e
                );
                return;
            }
        };
        match handle.load_state(state) {
            Ok(()) => {
                self.with_plugin(channel_id, &device_path, |plugin| plugin.set_state_dirty());
                info!(
                    "Restored plugin state (channel {} device {})",
                    channel_id, device_path
                );
            }
            Err(e) => warn!(
                "Failed to load plugin state (channel {} device {}): {}",
                channel_id, device_path, e
            ),
        }
    }

    /// Add a plugin's audio-thread counters to the running totals for the next log.
    fn record_plugin_stats(&mut self, plugin: &PolledPlugin) {
        let s = plugin.stats;
        if s.deadline_misses == 0 && s.event_drops == 0 {
            return;
        }
        let entry = self
            .plugin_stats
            .entry((plugin.channel_id, plugin.device_path))
            .or_insert_with(|| PluginStatsLog {
                name: plugin.handle.device_name().to_string(),
                stats: PluginBlockStats::default(),
            });
        entry.stats.deadline_misses += s.deadline_misses;
        entry.stats.event_drops += s.event_drops;
    }

    /// Log and reset per-plugin problem counts every `PLUGIN_STATS_LOG_INTERVAL`.
    fn log_plugin_stats(&mut self) {
        let elapsed = self.plugin_stats_since.elapsed();
        if elapsed < PLUGIN_STATS_LOG_INTERVAL {
            return;
        }
        for ((channel_id, device_path), entry) in self.plugin_stats.drain() {
            let s = entry.stats;
            warn!(
                "Plugin {} (channel {} device {}) in the last {:.0}s: {} blocks missed the processing deadline, {} input events dropped",
                entry.name,
                channel_id,
                device_path,
                elapsed.as_secs_f32(),
                s.deadline_misses,
                s.event_drops
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
            AudioCommand::SavePluginState {
                channel_id,
                device_path,
            } => self.save_plugin_state(channel_id, device_path),
            AudioCommand::LoadPluginState {
                channel_id,
                device_path,
                state_base64,
            } => self.load_plugin_state(channel_id, device_path, &state_base64),
            AudioCommand::ClearChannelDevices { channel_id } => self.clear_devices(channel_id),
            AudioCommand::RemoveChannel { id } => self.remove_channel(id),
            AudioCommand::ClearProject => self.clear_project(),
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
            other => self.apply_locked(other),
        }
    }

    /// Apply a fast command with the state lock held.
    fn apply_locked(&self, cmd: AudioCommand) {
        let status = process_command(
            &mut self.lock_state(),
            cmd,
            self.max_buffer_size,
            &self.status_tx,
        );
        if let Some(status) = status {
            self.send_status(status);
        }
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

        for plugin in self.plugin_scanner.all_plugins() {
            let category = match plugin.category {
                DeviceCategory::Instrument => "instrument",
                DeviceCategory::Effect => "effect",
                DeviceCategory::Utility => "utility",
            }
            .to_string();

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
        info!("Advertised {} builtin devices", count);
        self.send_status(EngineStatus::BuiltinDevicesComplete { count });
    }

    /// Build a device with the lock released, then insert it into the parent list.
    #[allow(clippy::too_many_arguments)]
    fn add_device(
        &self,
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

        let Some(mut device) = self.device_factory.create(
            device_type,
            device_id,
            device_file,
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
            super::devices::container::remove_device(&mut channel.devices, &path)
        };
        if removed.is_none() {
            warn!("Invalid device path {} for channel {}", path, channel_id);
            return;
        }
        drop(removed);
        info!("Device removed from channel {} at {}", channel_id, path);
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

    /// Swap out all channels, tracks and clips under the lock and drop them afterwards.
    fn clear_project(&self) {
        let removed = {
            let mut state = self.lock_state();
            state.set_current_tick(0);
            state.set_fractional_tick_accumulator(0.0);
            let _ = state.take_playhead_midi_dispatch();
            (
                std::mem::take(&mut state.channels),
                std::mem::take(&mut state.tracks),
                std::mem::take(&mut state.clips),
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

    /// Open a subprocess plugin's GUI with the lock released, then ask Godot to size its window.
    fn open_plugin_gui(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_path: DevicePath,
        window_handle: Option<u64>,
    ) {
        let already_open = self
            .with_plugin(channel_id, &device_path, |plugin| plugin.is_gui_open())
            .unwrap_or(false);

        let (width, height) = if already_open {
            (800, 600)
        } else {
            match handle.open_gui(window_handle) {
                Ok((width, height, is_resizable)) => {
                    self.with_plugin(channel_id, &device_path, |plugin| plugin.set_gui_open(true));
                    info!(
                        "Opened GUI for subprocess plugin at channel {} device {} (window_handle: {:?}, size: {}x{}, resizable: {})",
                        channel_id, device_path, window_handle, width, height, is_resizable
                    );
                    (width, height)
                }
                Err(e) => {
                    warn!(
                        "Failed to open subprocess plugin GUI at channel {} device {}: {}",
                        channel_id, device_path, e
                    );
                    return;
                }
            }
        };

        self.send_status(EngineStatus::PluginGuiResizeRequest {
            channel_id,
            device_path,
            width,
            height,
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
            module: String::new(),
            enum_values: param.enum_values.clone(),
        });
    }
}
