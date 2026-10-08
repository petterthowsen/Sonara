//! Servicing devices on the command thread between commands: the plugin poll, crash handling
//! and per-plugin stats.

use std::sync::Arc;
use std::time::{Duration, Instant};
use tracing::{error, info, warn};

use super::plugins::{collect_sfizz_key_info, collect_sfizz_parameters};
use super::CommandWorker;
use crate::audio::commands::EngineStatus;
use crate::audio::devices::clap_host::subprocess_adapter::{
    PluginBlockStats, PluginIpcHandle, PluginLoad, HUNG_STALL_TIMEOUT,
};
use crate::audio::devices::clap_host::SubprocessClapAdapter;
use crate::audio::devices::{container, DevicePath, ParamId, ParamValue, SfizzDevice};
use crate::audio::ipc::PluginEvent;
use crate::audio::types::ChannelId;

/// How often per-plugin audio problems (dropouts, overflows, MIDI drops) are logged, if any.
const PLUGIN_STATS_LOG_INTERVAL: Duration = Duration::from_secs(10);

/// How often each plugin's processing stats are sent to Godot (`<device addr>/stats`).
const PLUGIN_STATS_REPORT_INTERVAL: Duration = Duration::from_secs(1);

/// A subprocess plugin collected under the state lock for `poll_devices` to service without it.
pub(super) struct PolledPlugin {
    pub(super) channel_id: ChannelId,
    pub(super) device_path: DevicePath,
    pub(super) handle: PluginIpcHandle,
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

/// Per-plugin audio problem counts since the last log.
pub(super) struct PluginStatsLog {
    name: String,
    stats: PluginBlockStats,
}

/// A plugin's stats since the last report to Godot.
#[derive(Default)]
pub(super) struct PluginStatsReport {
    window: PluginBlockStats,
    /// Deadline misses since the device was first seen.
    total_misses: u64,
    /// Blocks in the last report, so an idle plugin is reported once and then left alone.
    last_blocks: u64,
    /// Seen in this reporting interval; entries of removed devices are dropped.
    seen: bool,
}

impl CommandWorker {
    /// Service devices on behalf of the audio callback.
    ///
    /// Under the state lock: collect each ready subprocess plugin's IPC handle, queued
    /// automation writes and audio-thread counters, and any new SFZ parameter lists. With the
    /// lock released: send the writes, drain the events the plugins sent (parameter changes, GUI
    /// resize requests), detect dead subprocesses, and send statuses.
    pub(super) fn poll_devices(&mut self) {
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
                // The plugin may have been removed since the poll; that is not worth a log line.
                if let Ok(plugin) =
                    state.device_as_mut::<SubprocessClapAdapter>(channel_id, &device_path)
                {
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
    pub(super) fn mark_plugin_crashed(&self, plugin: &PolledPlugin) {
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

    /// Add a plugin's audio-thread counters to the running totals for the next log and the next
    /// report to Godot.
    pub(super) fn record_plugin_stats(&mut self, plugin: &PolledPlugin) {
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
    pub(super) fn report_plugin_stats(&mut self) {
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
    pub(super) fn log_plugin_stats(&mut self) {
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
}
