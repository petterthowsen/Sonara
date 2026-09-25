//! Audio device settings on the command thread (Phase 7): reopening the output stream on
//! another device, rate or buffer size, preparing devices for a new rate while it is stopped,
//! and following the PipeWire graph.

use tracing::{error, info, warn};

use super::CommandWorker;
use crate::audio::commands::{AudioConfigReport, EngineStatus};
use crate::audio::devices::clap_host::subprocess_adapter::PluginIpcHandle;
use crate::audio::devices::clap_host::SubprocessClapAdapter;
use crate::audio::devices::{container, DevicePath};
use crate::audio::pipewire::{describe_mismatch, required_period, GraphInfo};
use crate::audio::stream::{
    list_output_devices, StreamInfo, StreamRequest, DEFAULT_SAMPLE_RATE, MAX_PERIOD_FRAMES,
    MIN_PERIOD_FRAMES,
};
use crate::audio::types::{ChannelId, HARDWARE_OUTPUT_BASE};

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
            "Audio config requested: device '{}', {} Hz, {} frames",
            display_device(&request.device),
            request.sample_rate,
            request.period_frames
        );
        self.audio.request = request;
        self.apply_audio_config();
    }

    /// Reopen the stream for the current request. The steps run in this order so no callback
    /// ever sees a device at the wrong rate: stop the stream; resolve the config (the device
    /// may not support the requested rate); prepare every device for the resolved rate; start.
    /// A device that won't open falls back to the default device, then to the default config.
    pub(super) fn apply_audio_config(&mut self) {
        let request = self.audio.request.clone();
        let quantum_at = |rate: u32| {
            self.audio
                .graph
                .as_ref()
                .map_or(0, |graph| graph.quantum_at(rate))
        };
        let quantum = quantum_at(request.sample_rate);
        let first = StreamRequest {
            period_frames: required_period(request.period_frames, quantum),
            ..request.clone()
        };
        let mut candidates = vec![first.clone()];
        if !request.device.is_empty() {
            candidates.push(StreamRequest {
                device: String::new(),
                ..first.clone()
            });
        }
        let fallback = StreamRequest::default();
        let fallback = StreamRequest {
            period_frames: required_period(
                fallback.period_frames,
                quantum_at(fallback.sample_rate),
            ),
            ..fallback
        };
        if !candidates.contains(&fallback) {
            candidates.push(fallback);
        }

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
                        "Can't use output '{}': {}",
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
            match self.stream.start() {
                Ok(info) => {
                    started = Some((info, candidate.period_frames));
                    break;
                }
                Err(e) => {
                    warn!("Can't open output '{}': {}", resolved.device, e);
                    notices.push(format!("Couldn't open {}: {}.", resolved.device, e));
                }
            }
        }

        match &started {
            Some((info, opened_period)) => {
                self.audio.opened_period = *opened_period;
                if info.sample_rate != request.sample_rate {
                    notices.push(format!(
                        "{} doesn't run at {} Hz; using {} Hz.",
                        info.device, request.sample_rate, info.sample_rate
                    ));
                }
                if info.period_frames == 0 {
                    notices.push(format!(
                        "{} didn't accept a fixed buffer size; using its default.",
                        info.device
                    ));
                }
            }
            None => {
                error!("No audio output could be opened; the engine is silent");
                notices.push("No audio output could be opened.".to_string());
                self.audio.opened_period = 0;
            }
        }
        self.audio.notice = notices.join(" ");

        let new_rate = self.lock_state().device_sample_rate;
        if new_rate != old_rate {
            // Clips were decoded at the old rate. They keep playing at the right pitch (playback
            // compensates for the clip's rate), but Godot reloads them to resample properly.
            self.send_status(EngineStatus::AudioConfigChanged {
                sample_rate: new_rate.round() as u32,
            });
        }
        self.check_master_output();
        self.report_audio_config();
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
    /// the buffer had to grow or PipeWire resamples the engine, else INFO.
    pub(super) fn report_audio_config(&mut self) {
        let active = self.stream.active();
        let graph = self.audio.graph.clone().unwrap_or_default();
        let requested_period = self.audio.request.period_frames;
        let mismatch = active
            .as_ref()
            .map(|active| describe_mismatch(&graph, active, requested_period))
            .unwrap_or_default();
        if mismatch != self.audio.mismatch {
            let serious = active.as_ref().is_some_and(|active| {
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
        }));
    }

    /// `/audio/devices/request`: enumerate on a background thread (it opens every device).
    pub(super) fn list_audio_devices(&self) {
        let active = self.stream.active();
        let status_tx = self.status_tx.clone();
        std::thread::spawn(move || {
            let devices = list_output_devices(active.as_ref());
            let count = devices.len();
            for device in devices {
                let _ = status_tx.send(EngineStatus::AudioDeviceInfo(device));
            }
            let _ = status_tx.send(EngineStatus::AudioDevicesComplete { count });
            info!("Listed {} output devices", count);
        });
    }

    /// The PipeWire graph changed: grow (or restore) the buffer when the quantum needs it, and
    /// report the graph in `/audio/config`.
    pub(super) fn on_pipewire_graph(&mut self, graph: GraphInfo) {
        let requested = self.audio.request.period_frames;
        let rate = self
            .stream
            .active()
            .map_or(self.audio.request.sample_rate, |active| active.sample_rate);
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
        self.audio.graph = Some(graph);

        if self.audio.opened_period != 0 && needed != self.audio.opened_period {
            info!(
                "Reopening the output stream with a {}-frame buffer for PipeWire's {}-frame quantum (requested {}){}",
                needed, quantum, requested, hint
            );
            self.apply_audio_config();
        } else {
            self.report_audio_config();
        }
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
