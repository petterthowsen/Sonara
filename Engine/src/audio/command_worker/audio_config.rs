//! Audio device settings on the command thread (Phase 7, spec 041): reopening the output stream
//! on another driver, device, rate or buffer size, preparing devices for a new rate while it is
//! stopped, forcing PipeWire's quantum and rate on the PipeWire driver, and following the
//! PipeWire graph.

use tracing::{error, info, warn};

use super::CommandWorker;
use crate::audio::commands::{AudioConfigReport, EngineStatus};
use crate::audio::devices::clap_host::subprocess_adapter::PluginIpcHandle;
use crate::audio::devices::clap_host::SubprocessClapAdapter;
use crate::audio::devices::{container, DevicePath};
use crate::audio::mixing::ChannelPool;
use crate::audio::pipewire::{describe_mismatch, required_period, GraphInfo, RealtimeState};
use crate::audio::stream::{
    list_output_devices, Driver, StreamInfo, StreamRequest, DEFAULT_SAMPLE_RATE, MAX_PERIOD_FRAMES,
    MIN_PERIOD_FRAMES,
};
use crate::audio::types::{ChannelId, HARDWARE_OUTPUT_BASE};

/// Most processing threads Auto picks, the callback thread included.
const AUTO_MAX_THREADS: usize = 8;

/// Worker threads for a processing-threads setting on a machine with `cores` cores. The callback
/// thread is the first processing thread, so N threads is N − 1 workers. Auto (0) is
/// `min(cores / 2, 8)` threads, leaving half the cores to plugin hosts; an explicit setting is
/// capped at the core count.
fn pool_workers(requested: u32, cores: usize) -> usize {
    let threads = match requested {
        0 => (cores / 2).min(AUTO_MAX_THREADS),
        n => (n as usize).min(cores),
    };
    threads.saturating_sub(1)
}

/// Master's channel ID.
const MASTER_CHANNEL_ID: ChannelId = 1;

impl CommandWorker {
    /// `/audio/config/set`: remember the request and reopen the stream if it changed.
    pub(super) fn set_audio_config(&mut self, request: StreamRequest) {
        let request = StreamRequest {
            sample_rate: if request.sample_rate == 0 {
                DEFAULT_SAMPLE_RATE
            } else {
                request.sample_rate
            },
            period_frames: request
                .period_frames
                .clamp(MIN_PERIOD_FRAMES, MAX_PERIOD_FRAMES),
            ..request
        };
        if request == self.audio.request && self.stream.active().is_some() {
            self.report_audio_config();
            return;
        }
        info!(
            "Audio config requested: {} driver, device '{}', {} Hz, {} frames",
            request.driver.label(),
            display_device(&request.device),
            request.sample_rate,
            request.period_frames
        );
        self.audio.request = request;
        self.apply_audio_config();
    }

    /// Open the first stream, at engine start.
    pub fn open_output(&mut self) {
        self.apply_audio_config();
    }

    /// Reopen the stream for the current request. The steps run in this order so no callback
    /// ever sees a device at the wrong rate: stop the stream; resolve the config (the device
    /// may not support the requested rate); prepare every device for the resolved rate; force
    /// PipeWire's quantum and rate (PipeWire driver); start. A device that won't open falls back
    /// to the driver's default device, then (when PipeWire was asked for) to ALSA's, then to the
    /// default config.
    pub(super) fn apply_audio_config(&mut self) {
        let request = self.audio.request.clone();
        let candidates = self.stream_candidates(&request);

        let old_rate = self.lock_state().device_sample_rate;
        if let Err(e) = self.stream.stop() {
            warn!("Couldn't stop the output stream: {}", e);
        }

        let mut notices: Vec<String> = Vec::new();
        let mut started: Option<(StreamInfo, u32)> = None;
        for candidate in &candidates {
            let resolved = match self.stream.resolve(candidate) {
                Ok(resolved) => resolved,
                Err(e) => {
                    warn!(
                        "Can't use {} output '{}': {}",
                        candidate.driver.label(),
                        display_device(&candidate.device),
                        e
                    );
                    notices.push(format!(
                        "Couldn't use {}: {}.",
                        display_device(&candidate.device),
                        e
                    ));
                    continue;
                }
            };
            self.set_device_rate(resolved.sample_rate as f32);
            match resolved.driver {
                Driver::PipeWire => {
                    let quantum = if resolved.period_frames > 0 {
                        resolved.period_frames
                    } else {
                        candidate.period_frames
                    };
                    if let Some(notice) = self.force_clock(quantum, resolved.sample_rate) {
                        notices.push(notice);
                    }
                }
                Driver::Alsa => self.release_clock(),
            }
            match self.stream.start() {
                Ok(info) => {
                    started = Some((info, candidate.period_frames));
                    break;
                }
                Err(e) => {
                    warn!("Can't open output '{}': {}", resolved.label, e);
                    notices.push(format!("Couldn't open {}: {}.", resolved.label, e));
                }
            }
        }

        match &started {
            Some((info, opened_period)) => {
                self.audio.opened_period = *opened_period;
                if info.driver != request.driver {
                    notices.push(format!(
                        "{} isn't running; playing through {}.",
                        request.driver.label(),
                        info.driver.label()
                    ));
                }
                if info.sample_rate != request.sample_rate {
                    notices.push(format!(
                        "{} doesn't run at {} Hz; using {} Hz.",
                        info.label, request.sample_rate, info.sample_rate
                    ));
                }
                if info.period_frames == 0 {
                    notices.push(format!(
                        "{} didn't accept a fixed buffer size; using its default.",
                        info.label
                    ));
                }
            }
            None => {
                error!("No audio output could be opened; the engine is silent");
                notices.push("No audio output could be opened.".to_string());
                self.audio.opened_period = 0;
                self.release_clock();
            }
        }
        self.audio.notice = notices.join(" ");
        self.audio.forced_by_other = false;

        let new_rate = self.lock_state().device_sample_rate;
        if new_rate != old_rate {
            // Clips were decoded at the old rate. They keep playing at the right pitch (playback
            // compensates for the clip's rate), but Godot reloads them to resample properly.
            self.send_status(EngineStatus::AudioConfigChanged {
                sample_rate: new_rate.round() as u32,
            });
        }
        // The workers ask rtkit for realtime with the stream's period and rate, so they follow it.
        if started.is_some() {
            self.rebuild_pool(true);
        }
        self.check_master_output();
        self.report_audio_config();
    }

    /// `/engine/threads/set`: remember the setting and resize the worker pool if it changed.
    pub(super) fn set_processing_threads(&mut self, threads: u32) {
        self.processing_threads = threads;
        self.rebuild_pool(false);
    }

    /// Build the worker pool for the current setting and stream, outside the state lock, swap it
    /// in under the lock and drop the old one (which joins its threads) after unlocking. Without
    /// `force`, a pool that already has the right number of workers is kept.
    fn rebuild_pool(&mut self, force: bool) {
        let cores = std::thread::available_parallelism().map_or(1, |n| n.get());
        let workers = pool_workers(self.processing_threads, cores);
        let (current, state_rate) = {
            let state = self.lock_state();
            let current = state.pool.as_ref().map_or(0, |pool| pool.threads());
            (current, state.device_sample_rate as u32)
        };
        if !force && current == workers {
            return;
        }
        let (frames, rate) = match self.stream.active() {
            Some(info) if info.period_frames > 0 => (info.period_frames, info.sample_rate),
            Some(info) => (self.max_buffer_size as u32, info.sample_rate),
            None => (self.max_buffer_size as u32, state_rate),
        };
        let pool = (workers > 0).then(|| ChannelPool::new(workers, frames, rate));
        let old = std::mem::replace(&mut self.lock_state().pool, pool);
        drop(old);
        info!(
            "Processing threads: {} ({} worker threads, setting {})",
            workers + 1,
            workers,
            match self.processing_threads {
                0 => "Auto".to_string(),
                n => n.to_string(),
            }
        );
    }

    /// The configs to try for `request`, in order: the request; the driver's default device;
    /// ALSA's default device when PipeWire was asked for (PipeWire isn't running); the default
    /// config on either driver. On ALSA the period grows so the ring holds PipeWire's quantum.
    fn stream_candidates(&self, request: &StreamRequest) -> Vec<StreamRequest> {
        let adapt = |candidate: StreamRequest| {
            if candidate.driver != Driver::Alsa {
                return candidate;
            }
            let quantum = self
                .audio
                .graph
                .as_ref()
                .map_or(0, |graph| graph.quantum_at(candidate.sample_rate));
            StreamRequest {
                period_frames: required_period(candidate.period_frames, quantum),
                ..candidate
            }
        };
        let defaults = StreamRequest::default();
        let mut wanted = vec![request.clone()];
        if !request.device.is_empty() {
            wanted.push(StreamRequest {
                device: String::new(),
                ..request.clone()
            });
        }
        if request.driver == Driver::PipeWire {
            wanted.push(StreamRequest {
                driver: Driver::Alsa,
                device: String::new(),
                ..request.clone()
            });
        }
        wanted.push(StreamRequest {
            driver: request.driver,
            ..defaults.clone()
        });
        wanted.push(StreamRequest {
            driver: Driver::Alsa,
            ..defaults
        });

        let mut candidates: Vec<StreamRequest> = Vec::new();
        for candidate in wanted.into_iter().map(adapt) {
            if !candidates.contains(&candidate) {
                candidates.push(candidate);
            }
        }
        candidates
    }

    /// Force PipeWire's quantum and rate to the stream's. Returns a notice when it can't.
    fn force_clock(&mut self, quantum: u32, rate: u32) -> Option<String> {
        let result = self
            .audio
            .forced
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .apply(quantum, rate);
        result.err().map(|e| {
            warn!("Can't force PipeWire's quantum and rate: {}", e);
            format!(
                "Couldn't set PipeWire's buffer size ({}); the engine follows the graph's quantum.",
                e
            )
        })
    }

    /// Stop forcing PipeWire's quantum and rate, restoring what was there before.
    fn release_clock(&mut self) {
        self.audio
            .forced
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .restore();
    }

    /// Prepare every device for `sample_rate` (no-op when it's the current rate). The stream is
    /// stopped, so the lock is uncontended; plugin re-activation still runs with it released.
    fn set_device_rate(&mut self, sample_rate: f32) {
        let max_frames = self.max_buffer_size;
        let mut plugins: Vec<(ChannelId, DevicePath, PluginIpcHandle)> = Vec::new();
        {
            let mut state = self.lock_state();
            if state.device_sample_rate == sample_rate {
                return;
            }
            info!(
                "Device sample rate {} Hz → {} Hz: preparing devices",
                state.device_sample_rate, sample_rate
            );
            state.device_sample_rate = sample_rate;
            state.settings.sample_rate = sample_rate.round() as i32;
            state.metronome.prepare(sample_rate, max_frames);
            for (&channel_id, channel) in state.channels.iter_mut() {
                channel.set_sample_rate(sample_rate);
                container::visit_devices_mut(&mut channel.devices, &mut |device_path, device| {
                    device.prepare(sample_rate, max_frames);
                    if let Some(plugin) =
                        device.as_any_mut().downcast_mut::<SubprocessClapAdapter>()
                    {
                        if plugin.needs_reactivation() {
                            plugins.push((channel_id, *device_path, plugin.ipc_handle()));
                        }
                    }
                });
            }
        }
        self.device_factory.set_sample_rate(sample_rate);
        for (channel_id, device_path, handle) in plugins {
            self.reactivate_plugin(channel_id, device_path, &handle);
        }
        // The 1 s compensation limit is in frames at the new rate
        self.refresh_latency();
    }

    /// Re-activate a plugin at the engine's current rate (the host deactivates it first).
    pub(super) fn reactivate_plugin(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        handle: &PluginIpcHandle,
    ) {
        match handle.activate() {
            Ok(latency) => {
                self.with_plugin(channel_id, &device_path, |plugin| {
                    plugin.set_active_state(true, latency)
                });
                info!(
                    "Re-activated plugin {} (channel {} device {}) at the new sample rate",
                    handle.device_name(),
                    channel_id,
                    device_path
                );
            }
            Err(e) => warn!(
                "Couldn't re-activate plugin {} (channel {} device {}) at the new sample rate: {}",
                handle.device_name(),
                channel_id,
                device_path,
                e
            ),
        }
    }

    /// Warn when master routes to an output pair the device doesn't have (it plays on 1/2).
    pub(super) fn check_master_output(&self) {
        let Some(active) = self.stream.active() else {
            return;
        };
        let output = self
            .lock_state()
            .channels
            .get(&MASTER_CHANNEL_ID)
            .and_then(|master| master.output_channel_id);
        if let Some(output) = output.filter(|&id| id >= HARDWARE_OUTPUT_BASE) {
            let pair = output - HARDWARE_OUTPUT_BASE;
            if pair >= active.output_pairs() {
                warn!(
                    "Master routes to hardware output {} (outputs {}/{}), but {} has {} output pair(s); playing on outputs 1/2",
                    output,
                    pair * 2 + 1,
                    pair * 2 + 2,
                    active.device,
                    active.output_pairs()
                );
            }
        }
    }

    /// Send `/audio/config`, logging a graph/stream conflict once when it appears: a WARN when
    /// the buffer had to grow, PipeWire resamples the engine or another application forces the
    /// graph, else INFO.
    pub(super) fn report_audio_config(&mut self) {
        let active = self.stream.active();
        let graph = self.audio.graph.clone().unwrap_or_default();
        let requested_period = self.audio.request.period_frames;
        let forced_by_other = self.audio.forced_by_other;
        let mismatch = active
            .as_ref()
            .map(|active| describe_mismatch(&graph, active, requested_period, forced_by_other))
            .unwrap_or_default();
        if mismatch != self.audio.mismatch {
            let serious = forced_by_other
                || active.as_ref().is_some_and(|active| {
                    active.period_frames > requested_period
                        || (graph.rate > 0 && graph.rate != active.sample_rate)
                });
            if mismatch.is_empty() {
                info!("PipeWire graph and output stream agree again");
            } else if serious {
                warn!("{}", mismatch);
            } else {
                info!("{}", mismatch);
            }
            self.audio.mismatch = mismatch.clone();
        }
        self.send_status(EngineStatus::AudioConfig(AudioConfigReport {
            active,
            requested: self.audio.request.clone(),
            graph_quantum: graph.quantum,
            graph_rate: graph.rate,
            mismatch,
            notice: self.audio.notice.clone(),
            output_latency_us: self.audio.latency_us,
            realtime: self.audio.realtime,
        }));
    }

    /// `/audio/devices/request`: enumerate the requested driver's devices on a background thread
    /// (it opens every ALSA device).
    pub(super) fn list_audio_devices(&self) {
        let active = self.stream.active();
        let driver = self.audio.request.driver;
        let status_tx = self.status_tx.clone();
        std::thread::spawn(move || {
            let devices = list_output_devices(driver, active.as_ref());
            let count = devices.len();
            for device in devices {
                let _ = status_tx.send(EngineStatus::AudioDeviceInfo(device));
            }
            let _ = status_tx.send(EngineStatus::AudioDevicesComplete { count });
            info!("Listed {} {} output devices", count, driver.label());
        });
    }

    /// The PipeWire graph changed. On ALSA: grow (or restore) the buffer when the quantum needs
    /// it. On PipeWire the engine plays at whatever quantum the graph runs and only notes when
    /// another application forces it (the next settings change forces again). Either way the
    /// graph goes into `/audio/config`.
    pub(super) fn on_pipewire_graph(&mut self, graph: GraphInfo) {
        let requested = self.audio.request.period_frames;
        let active = self.stream.active();
        let rate = active
            .as_ref()
            .map_or(self.audio.request.sample_rate, |active| active.sample_rate);
        let native = active
            .as_ref()
            .is_some_and(|active| active.driver == Driver::PipeWire);
        let needed = required_period(requested, graph.quantum_at(rate));
        let previous_quantum = self.audio.graph.as_ref().map_or(0, |g| g.quantum);
        let previous_rate = self.audio.graph.as_ref().map_or(0, |g| g.rate);
        if graph.quantum != previous_quantum || graph.rate != previous_rate {
            info!(
                "PipeWire graph: quantum {} at {} Hz (forced quantum {}, forced rate {}), engine node {:?}",
                graph.quantum, graph.rate, graph.force_quantum, graph.force_rate, graph.node_id
            );
        }
        let hint = forced_quantum_hint(&graph);
        let quantum = graph.quantum;
        self.audio.forced_by_other = native
            && !self
                .audio
                .forced
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_ours(&graph);
        self.audio.graph = Some(graph);

        if !native && self.audio.opened_period != 0 && needed != self.audio.opened_period {
            info!(
                "Reopening the output stream with a {}-frame buffer for PipeWire's {}-frame quantum (requested {}){}",
                needed, quantum, requested, hint
            );
            self.apply_audio_config();
        } else {
            self.report_audio_config();
        }
    }

    /// The monitor measured new output latency or realtime state.
    pub(super) fn on_output_health(&mut self, latency_us: u32, realtime: RealtimeState) {
        if latency_us == self.audio.latency_us && realtime == self.audio.realtime {
            return;
        }
        self.audio.latency_us = latency_us;
        self.audio.realtime = realtime;
        self.report_audio_config();
    }
}

/// " (clock.force-quantum N)" when the quantum is forced, for log lines.
fn forced_quantum_hint(graph: &GraphInfo) -> String {
    if graph.force_quantum > 0 {
        format!(
            " (forced: `pw-metadata -n settings 0 clock.force-quantum {}`)",
            graph.force_quantum
        )
    } else {
        String::new()
    }
}

/// A requested device name for logs and notices.
fn display_device(device: &str) -> &str {
    if device.is_empty() {
        "the default device"
    } else {
        device
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_processing_threads_leave_half_the_cores() {
        assert_eq!(pool_workers(0, 12), 5);
        assert_eq!(pool_workers(0, 2), 0);
        assert_eq!(pool_workers(0, 32), 7);
        assert_eq!(pool_workers(0, 1), 0);
        assert_eq!(pool_workers(1, 12), 0, "1 thread is the callback alone");
        assert_eq!(pool_workers(4, 12), 3);
        assert_eq!(pool_workers(64, 12), 11, "capped at the core count");
    }
}
