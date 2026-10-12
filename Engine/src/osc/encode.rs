//! Engine statuses as OSC messages for Godot. Addresses, argument order and OSC types are part of
//! the protocol (`docs/subsystems/osc-protocol.md`); Godot depends on them.

use rosc::{OscMessage, OscType};
use tracing::info;

use crate::audio::clip::ClipLoadState;
use crate::audio::commands::BuiltinParamInfo;
use crate::audio::EngineStatus;

/// The OSC messages for one engine status, in send order. Pure: no socket, so the protocol can be
/// unit-tested. Each status encodes to exactly one message today.
pub(super) fn encode_status(status: EngineStatus) -> Vec<OscMessage> {
    let (addr, args) = match status {
        EngineStatus::PlayheadUpdate(ticks) => (
            "/status/playhead".to_string(),
            vec![OscType::Int(ticks as i32)],
        ),
        EngineStatus::PlayingStateChanged(playing) => (
            "/status/playing".to_string(),
            vec![OscType::Int(if playing { 1 } else { 0 })],
        ),
        EngineStatus::PreviewStatus {
            path,
            state,
            pos_s,
            duration_s,
        } => (
            "/preview/status".to_string(),
            vec![
                OscType::String(path.to_string()),
                OscType::Int(state.osc_value()),
                OscType::Float(pos_s),
                OscType::Float(duration_s),
            ],
        ),
        EngineStatus::RenderProgress { job_id, fraction } => (
            "/render/progress".to_string(),
            vec![OscType::String(job_id), OscType::Float(fraction)],
        ),
        EngineStatus::RenderDone { job_id, outputs } => {
            let mut args = vec![OscType::String(job_id)];
            args.extend(
                outputs
                    .into_iter()
                    .map(|path| OscType::String(path.to_string_lossy().into_owned())),
            );
            ("/render/done".to_string(), args)
        }
        EngineStatus::RenderFailed { job_id, error } => (
            "/render/failed".to_string(),
            vec![OscType::String(job_id), OscType::String(error)],
        ),
        EngineStatus::ChannelPeaks {
            id,
            peak_left,
            peak_right,
            rms_left,
            rms_right,
        } => {
            // New path-based format: /channel/{id}/peak [peak_left, peak_right, rms_left, rms_right]
            (
                format!("/channel/{}/peak", id),
                vec![
                    OscType::Float(peak_left),
                    OscType::Float(peak_right),
                    OscType::Float(rms_left),
                    OscType::Float(rms_right),
                ],
            )
        }
        EngineStatus::ClipLoadStateChanged {
            clip_id,
            state,
            source_path,
            cache_key,
            sample_rate,
            channels,
        } => {
            let (state_label, req_id, message) = match state {
                ClipLoadState::Unloaded => ("unloaded".to_string(), String::new(), String::new()),
                ClipLoadState::Loading { req_id } => ("loading".to_string(), req_id, String::new()),
                ClipLoadState::Ready { req_id } => ("ready".to_string(), req_id, String::new()),
                ClipLoadState::Failed { req_id, message } => {
                    ("failed".to_string(), req_id.unwrap_or_default(), message)
                }
            };

            (
                format!("/clip/{}/load_state", clip_id),
                vec![
                    OscType::String(state_label),
                    OscType::String(req_id),
                    OscType::String(source_path.unwrap_or_default()),
                    OscType::String(cache_key.unwrap_or_default()),
                    OscType::Int(sample_rate.unwrap_or(0) as i32),
                    OscType::Int(channels.unwrap_or(0) as i32),
                    OscType::String(message),
                ],
            )
        }
        EngineStatus::DeviceActiveChanged {
            channel_id,
            device_path,
            active,
        } => (
            device_path.to_osc_addr(channel_id, "active"),
            vec![OscType::Int(if active { 1 } else { 0 })],
        ),
        EngineStatus::DeviceEnabledChanged {
            channel_id,
            device_path,
            enabled,
        } => (
            device_path.to_osc_addr(channel_id, "enabled"),
            vec![OscType::Int(if enabled { 1 } else { 0 })],
        ),
        EngineStatus::DeviceLoadingStateChanged {
            channel_id,
            device_path,
            state,
        } => (
            device_path.to_osc_addr(channel_id, "loading_state"),
            vec![OscType::String(state)],
        ),
        EngineStatus::SamplerZoneLoadingState {
            channel_id,
            device_path,
            zone_id,
            state,
        } => (
            device_path.to_osc_addr(channel_id, &format!("zone/{zone_id}/loading_state")),
            vec![OscType::String(state)],
        ),
        EngineStatus::DeviceCrashed {
            channel_id,
            device_path,
            reason,
            stderr,
            pid,
            log_path,
        } => (
            device_path.to_osc_addr(channel_id, "crashed"),
            vec![
                OscType::String(reason),
                OscType::String(stderr),
                OscType::Int(pid as i32),
                OscType::String(log_path),
            ],
        ),
        EngineStatus::ChannelPerf {
            channel_id,
            load_avg,
            load_peak,
            out_latency_frames,
            devices,
        } => {
            let mut args = Vec::with_capacity(5 + devices.len() * 2);
            args.push(OscType::Int(channel_id as i32));
            args.push(OscType::Float(load_avg));
            args.push(OscType::Float(load_peak));
            args.push(OscType::Int(out_latency_frames as i32));
            args.push(OscType::Int(devices.len() as i32));
            for (avg, peak) in devices {
                args.push(OscType::Float(avg));
                args.push(OscType::Float(peak));
            }
            ("/status/channel_perf".to_string(), args)
        }
        EngineStatus::EnginePerf {
            processing_threads,
            threads_realtime,
            output_latency_frames,
            over_limit_channels,
            sample_rate,
        } => (
            "/status/engine_perf".to_string(),
            vec![
                OscType::Int(processing_threads as i32),
                OscType::String(threads_realtime),
                OscType::Int(output_latency_frames as i32),
                OscType::Int(over_limit_channels as i32),
                OscType::Int(sample_rate as i32),
            ],
        ),
        EngineStatus::PluginStats {
            channel_id,
            device_path,
            load_avg,
            load_peak,
            process_avg_us,
            process_max_us,
            blocks,
            deadline_misses,
            total_misses,
            struggling,
        } => (
            device_path.to_osc_addr(channel_id, "stats"),
            vec![
                OscType::Float(load_avg),
                OscType::Float(load_peak),
                OscType::Float(process_avg_us),
                OscType::Float(process_max_us),
                OscType::Int(osc_count(blocks)),
                OscType::Int(osc_count(deadline_misses)),
                OscType::Int(osc_count(total_misses)),
                OscType::Int(struggling as i32),
            ],
        ),
        EngineStatus::PluginHost {
            channel_id,
            device_path,
            mode,
            host_key,
            pid,
        } => (
            device_path.to_osc_addr(channel_id, "host"),
            vec![
                OscType::String(mode),
                OscType::String(host_key),
                OscType::Int(pid as i32),
            ],
        ),
        EngineStatus::PluginGuiOpened {
            channel_id,
            device_path,
            width,
            height,
            resizable,
            floating,
        } => (
            device_path.to_osc_addr(channel_id, "gui/opened"),
            vec![
                OscType::Int(width as i32),
                OscType::Int(height as i32),
                OscType::Int(resizable as i32),
                OscType::Int(floating as i32),
            ],
        ),
        // The main loop also resizes a floating host window; Godot needs the size to lay out
        // an embedded GUI.
        EngineStatus::PluginGuiResizeRequest {
            channel_id,
            device_path,
            width,
            height,
        } => (
            device_path.to_osc_addr(channel_id, "gui/size"),
            vec![OscType::Int(width as i32), OscType::Int(height as i32)],
        ),
        EngineStatus::PluginGuiClosed {
            channel_id,
            device_path,
        } => (device_path.to_osc_addr(channel_id, "gui/closed"), vec![]),
        EngineStatus::PluginScanComplete { count } => (
            "/plugin/scan_complete".to_string(),
            vec![OscType::Int(count as i32)],
        ),
        EngineStatus::PluginInfo {
            id,
            name,
            vendor,
            version,
            category,
            description,
            path,
            features,
            format,
        } => {
            tracing::info!("📨 Sending plugin info: {} ({}, {})", name, id, format);
            let mut args = vec![
                OscType::String(id.clone()),
                OscType::String(name),
                OscType::String(vendor),
                OscType::String(version),
                OscType::String(category),
            ];
            // Add description if present, otherwise send empty string
            args.push(OscType::String(description.unwrap_or_default()));
            // Add path
            args.push(OscType::String(path));
            // Add feature tags, joined with commas
            args.push(OscType::String(features.join(",")));
            // Add the plugin format ("clap" or "vst3")
            args.push(OscType::String(format));
            ("/plugin/info".to_string(), args)
        }
        EngineStatus::BuiltinDeviceInfo {
            id,
            name,
            category,
            description,
            accepts_midi,
            audio_in_channels,
            audio_out_channels,
            supports_file_loading,
            file_extensions,
            file_type_description,
            is_container,
            parameters,
            default_modulators,
            slots,
        } => {
            tracing::info!("📨 Sending builtin device info: {} ({})", name, id);

            // Send device basic info
            let mut args = vec![
                OscType::String(id.clone()),
                OscType::String(name),
                OscType::String(category),
                OscType::String(description),
                OscType::Int(if accepts_midi { 1 } else { 0 }),
                OscType::Int(audio_in_channels as i32),
                OscType::Int(audio_out_channels as i32),
                OscType::Int(if supports_file_loading { 1 } else { 0 }),
                OscType::String(file_type_description),
                OscType::Int(file_extensions.len() as i32),
            ];

            for ext in file_extensions {
                args.push(OscType::String(ext));
            }

            args.push(OscType::Int(parameters.len() as i32));

            // Add all parameters inline (id, name, unit, type, syncable, min, max, default,
            // is_log, skew, enum_count, enum_values..., module, automatable, modulatable)
            for param in &parameters {
                push_param_args(&mut args, param);
            }

            args.push(OscType::Int(if is_container { 1 } else { 0 }));

            // Default modulators: count, then (kind, name, params, routes) each.
            args.push(OscType::Int(default_modulators.len() as i32));
            for modulator in &default_modulators {
                args.push(OscType::String(modulator.kind.id().to_string()));
                args.push(OscType::String(modulator.name.clone()));
                args.push(OscType::Int(modulator.params.len() as i32));
                for (param_id, value) in &modulator.params {
                    args.push(OscType::Int(*param_id as i32));
                    args.push(OscType::Float(*value));
                }
                args.push(OscType::Int(modulator.routes.len() as i32));
                for (target, amount) in &modulator.routes {
                    args.push(OscType::String(target.clone()));
                    args.push(OscType::Float(*amount));
                }
            }

            // Device slots (spec 040): count, then (key, name, kind) each.
            args.push(OscType::Int(slots.len() as i32));
            for (key, name, kind) in slots {
                args.push(OscType::String(key));
                args.push(OscType::String(name));
                args.push(OscType::String(kind));
            }

            ("/builtin/info".to_string(), args)
        }
        EngineStatus::BuiltinDevicesComplete { count } => (
            "/builtin/complete".to_string(),
            vec![OscType::Int(count as i32)],
        ),
        EngineStatus::AudioDeviceInfo(device) => {
            let mut args = vec![
                OscType::String(device.id),
                OscType::String(device.label),
                OscType::Int(device.is_default as i32),
                OscType::Int(device.min_period as i32),
                OscType::Int(device.max_period as i32),
                OscType::Int(device.channels as i32),
            ];
            args.extend(
                device
                    .sample_rates
                    .iter()
                    .map(|&rate| OscType::Int(rate as i32)),
            );
            ("/audio/device".to_string(), args)
        }
        EngineStatus::AudioDevicesComplete { count } => (
            "/audio/devices/complete".to_string(),
            vec![OscType::Int(count as i32)],
        ),
        EngineStatus::AudioConfig(report) => {
            ("/audio/config".to_string(), audio_config_args(report))
        }
        EngineStatus::AudioConfigChanged { sample_rate } => (
            "/audio/config/changed".to_string(),
            vec![OscType::Int(sample_rate as i32)],
        ),
        EngineStatus::PluginParameterInfo {
            channel_id,
            device_path,
            param_id,
            name,
            min,
            max,
            default,
            group,
            param_type,
            is_hidden,
            is_read_only,
            is_bypass,
            is_modulatable,
            module,
            enum_values,
            unit,
            display,
        } => {
            let param_type_str = match param_type {
                crate::audio::devices::ParamType::Float => "float",
                crate::audio::devices::ParamType::Bool => "bool",
                crate::audio::devices::ParamType::Enum => "enum",
            };
            // Bitmask: 1 = hidden, 2 = read-only, 4 = bypass, 8 = modulatable
            let flags = (is_hidden as i32)
                | ((is_read_only as i32) << 1)
                | ((is_bypass as i32) << 2)
                | ((is_modulatable as i32) << 3);

            let mut args = vec![
                OscType::Int(param_id as i32),
                OscType::String(name),
                OscType::Float(min),
                OscType::Float(max),
                OscType::Float(default),
                OscType::String(group),
                OscType::String(param_type_str.to_string()),
                OscType::Int(flags),
                OscType::String(module),
                OscType::Int(enum_values.len() as i32),
            ];
            for ev in enum_values {
                args.push(OscType::String(ev));
            }
            args.push(OscType::String(unit));
            args.push(OscType::Int(display.len() as i32));
            args.extend(display.into_iter().map(OscType::Float));

            (device_path.to_osc_addr(channel_id, "param/info"), args)
        }
        EngineStatus::PluginParameterCount {
            channel_id,
            device_path,
            count,
        } => (
            device_path.to_osc_addr(channel_id, "param/count"),
            vec![OscType::Int(count as i32)],
        ),
        EngineStatus::SfzKeyInfo {
            channel_id,
            device_path,
            keys,
            ranges,
        } => (
            device_path.to_osc_addr(channel_id, "keys/info"),
            sfz_key_info_args(&keys, &ranges),
        ),
        EngineStatus::PluginStateSaved {
            channel_id,
            device_path,
            file_path,
            size,
        } => (
            device_path.to_osc_addr(channel_id, "state/saved"),
            vec![
                OscType::String(file_path),
                OscType::Int(size.clamp(-1, i32::MAX as i64) as i32),
            ],
        ),
        EngineStatus::PluginParameterValueChanged {
            channel_id,
            device_path,
            param_id,
            value,
        } => {
            let addr = device_path.to_osc_addr(channel_id, &format!("param/{}/value", param_id));
            info!("📡 Sending OSC: {} [{}]", addr, value);
            (addr, vec![OscType::Float(value)])
        }
        EngineStatus::ModulatorAdded {
            channel_id,
            device_path,
            mod_id,
            kind,
        } => (
            device_path.to_osc_addr(channel_id, "modulator/add"),
            vec![OscType::Int(mod_id as i32), OscType::String(kind)],
        ),
        EngineStatus::ModulatorRemoved {
            channel_id,
            device_path,
            mod_id,
        } => (
            device_path.to_osc_addr(channel_id, &format!("modulator/{mod_id}/remove")),
            vec![OscType::Int(mod_id as i32)],
        ),
        EngineStatus::ModulatorParamChanged {
            channel_id,
            device_path,
            mod_id,
            param_id,
            value,
        } => (
            device_path.to_osc_addr(
                channel_id,
                &format!("modulator/{mod_id}/param/{param_id}/value"),
            ),
            vec![OscType::Float(value)],
        ),
        EngineStatus::ModulatorRouteChanged {
            channel_id,
            device_path,
            mod_id,
            target,
            amount,
        } => (
            device_path.to_osc_addr(channel_id, &format!("modulator/{mod_id}/route/set")),
            vec![OscType::String(target), OscType::Float(amount)],
        ),
        EngineStatus::ModulatorsCleared {
            channel_id,
            device_path,
        } => (
            device_path.to_osc_addr(channel_id, "modulator/clear"),
            vec![],
        ),
        EngineStatus::ModulatorKindsInfo { count } => (
            "/builtin/modulator_info".to_string(),
            vec![OscType::Int(count as i32)],
        ),
        EngineStatus::ModulatorKindInfo {
            id,
            name,
            bipolar,
            params,
        } => {
            let mut args = vec![
                OscType::String(id),
                OscType::String(name),
                OscType::Int(if bipolar { 1 } else { 0 }),
                OscType::Int(params.len() as i32),
            ];
            for param in &params {
                push_param_args(&mut args, param);
            }
            ("/builtin/modulator_kind".to_string(), args)
        }
        EngineStatus::ModulatorKindsComplete { count } => (
            "/builtin/modulator_complete".to_string(),
            vec![OscType::Int(count as i32)],
        ),
        EngineStatus::LogMessage { level, message } => (
            "/log".to_string(),
            vec![OscType::String(level), OscType::String(message)],
        ),
        EngineStatus::EngineStats {
            load_avg,
            load_peak,
            xruns,
            lock_misses,
            callbacks,
            frames,
            plugin_underruns,
            ..
        } => (
            "/status/engine_stats".to_string(),
            vec![
                OscType::Float(load_avg),
                OscType::Float(load_peak),
                OscType::Int(osc_count(xruns)),
                OscType::Int(osc_count(lock_misses)),
                OscType::Int(osc_count(callbacks)),
                OscType::Int(frames as i32),
                OscType::Int(osc_count(plugin_underruns)),
            ],
        ),
        EngineStatus::DeviceData {
            channel_id,
            device_path,
            data_type,
            data,
        } => (
            device_path.to_osc_addr(channel_id, "data"),
            vec![OscType::String(data_type), OscType::Blob(data)],
        ),
        EngineStatus::DeviceSleepStatus {
            channel_id,
            device_path,
            is_sleeping,
        } => (
            device_path.to_osc_addr(channel_id, "sleep"),
            vec![OscType::Int(if is_sleeping { 1 } else { 0 })],
        ),
    };

    vec![OscMessage { addr, args }]
}

/// `/audio/config` arguments: the running stream (device "" and zeros when none could be
/// opened), then the request, the PipeWire graph, the two warning texts, and (spec 041) the
/// drivers, the device's readable name, the measured output latency and the realtime state.
fn audio_config_args(report: crate::audio::commands::AudioConfigReport) -> Vec<OscType> {
    let active = report.active;
    let (device, is_default, rate, period, latency, pairs) = match &active {
        Some(a) => (
            a.device.clone(),
            a.is_default_device,
            a.sample_rate,
            a.period_frames,
            a.latency_ms(),
            a.output_pairs(),
        ),
        None => (String::new(), false, 0, 0, 0.0, 0),
    };
    let (driver, label) = match &active {
        Some(a) => (a.driver.as_str(), a.label.clone()),
        None => ("", String::new()),
    };
    vec![
        OscType::String(device),
        OscType::Int(rate as i32),
        OscType::Int(period as i32),
        OscType::Float(latency),
        OscType::Int(pairs as i32),
        OscType::Int(is_default as i32),
        OscType::String(report.requested.device),
        OscType::Int(report.requested.sample_rate as i32),
        OscType::Int(report.requested.period_frames as i32),
        OscType::Int(report.graph_quantum as i32),
        OscType::Int(report.graph_rate as i32),
        OscType::String(report.mismatch),
        OscType::String(report.notice),
        OscType::String(driver.to_string()),
        OscType::String(report.requested.driver.as_str().to_string()),
        OscType::String(label),
        OscType::Float(report.output_latency_us as f32 / 1000.0),
        OscType::String(report.realtime.as_str().to_string()),
    ]
}

/// Clamp a running counter into an OSC int32 argument.
fn osc_count(count: u64) -> i32 {
    count.min(i32::MAX as u64) as i32
}

/// Append one parameter's typed descriptor to a `/builtin/*` message.
fn push_param_args(args: &mut Vec<OscType>, param: &BuiltinParamInfo) {
    args.push(OscType::Int(param.id as i32));
    args.push(OscType::String(param.name.clone()));
    args.push(OscType::String(param.unit.clone()));
    let ty_str = match param.param_type {
        crate::audio::devices::ParamType::Float => "float",
        crate::audio::devices::ParamType::Bool => "bool",
        crate::audio::devices::ParamType::Enum => "enum",
    };
    args.push(OscType::String(ty_str.to_string()));
    args.push(OscType::Int(if param.syncable { 1 } else { 0 }));
    args.push(OscType::Float(param.min));
    args.push(OscType::Float(param.max));
    args.push(OscType::Float(param.default));
    args.push(OscType::Int(if param.is_logarithmic { 1 } else { 0 }));
    args.push(OscType::Float(param.skew));
    args.push(OscType::Int(param.enum_values.len() as i32));
    for ev in &param.enum_values {
        args.push(OscType::String(ev.clone()));
    }
    args.push(OscType::String(param.module.clone()));
    args.push(OscType::Int(if param.is_automation_safe { 1 } else { 0 }));
    args.push(OscType::Int(if param.is_modulatable { 1 } else { 0 }));
}

/// Args for `.../keys/info`: the key count, `(key, is_keyswitch, label)` per key, then the range
/// count and `(lo, hi)` per playable range.
fn sfz_key_info_args(keys: &[(u8, bool, String)], ranges: &[(u8, u8)]) -> Vec<OscType> {
    let mut args = Vec::with_capacity(2 + keys.len() * 3 + ranges.len() * 2);
    args.push(OscType::Int(keys.len() as i32));
    for (key, is_keyswitch, label) in keys {
        args.push(OscType::Int(*key as i32));
        args.push(OscType::Int(*is_keyswitch as i32));
        args.push(OscType::String(label.clone()));
    }
    args.push(OscType::Int(ranges.len() as i32));
    for (lo, hi) in ranges {
        args.push(OscType::Int(*lo as i32));
        args.push(OscType::Int(*hi as i32));
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::{DevicePath, ParamType};
    use crate::osc::parse::{osc_arg_types, test_support::string};

    /// The single message a status encodes to, as `(address, type tags)`.
    fn wire(status: EngineStatus) -> (String, String, Vec<OscType>) {
        let mut messages = encode_status(status);
        assert_eq!(messages.len(), 1, "a status encodes to one message");
        let msg = messages.remove(0);
        let tags = osc_arg_types(&msg.args);
        (msg.addr, tags, msg.args)
    }

    #[test]
    fn channel_perf_encodes_a_variable_device_count() {
        let (addr, tags, args) = wire(EngineStatus::ChannelPerf {
            channel_id: 7,
            load_avg: 0.25,
            load_peak: 0.5,
            out_latency_frames: 128,
            devices: vec![(0.1, 0.2), (0.3, 0.4)],
        });
        assert_eq!(addr, "/status/channel_perf");
        assert_eq!(tags, "i f f i i f f f f");
        assert_eq!(args[0], OscType::Int(7));
        assert_eq!(args[3], OscType::Int(128));
        assert_eq!(args[4], OscType::Int(2));
        assert_eq!(args[7], OscType::Float(0.3));

        let (_, tags, args) = wire(EngineStatus::ChannelPerf {
            channel_id: 2,
            load_avg: 0.0,
            load_peak: 0.0,
            out_latency_frames: 0,
            devices: Vec::new(),
        });
        assert_eq!(tags, "i f f i i");
        assert_eq!(args[4], OscType::Int(0));
    }

    #[test]
    fn engine_perf_is_threads_realtime_latency_over_limit_rate() {
        let (addr, tags, args) = wire(EngineStatus::EnginePerf {
            processing_threads: 4,
            threads_realtime: "granted".into(),
            output_latency_frames: 256,
            over_limit_channels: 1,
            sample_rate: 48_000,
        });
        assert_eq!(addr, "/status/engine_perf");
        assert_eq!(tags, "i s i i i");
        assert_eq!(args[1], string("granted"));
        assert_eq!(args[4], OscType::Int(48_000));
    }

    #[test]
    fn preview_status_is_path_state_position_duration() {
        use crate::audio::preview::PreviewState;
        let (addr, tags, args) = wire(EngineStatus::PreviewStatus {
            path: "/s/kick.wav".into(),
            state: PreviewState::Playing,
            pos_s: 0.25,
            duration_s: 1.5,
        });
        assert_eq!(addr, "/preview/status");
        assert_eq!(tags, "s i f f");
        assert_eq!(args[0], string("/s/kick.wav"));
        assert_eq!(args[1], OscType::Int(2));
        assert_eq!(args[2], OscType::Float(0.25));
        assert_eq!(args[3], OscType::Float(1.5));
    }

    fn param(id: u32, name: &str, param_type: ParamType) -> BuiltinParamInfo {
        BuiltinParamInfo {
            id,
            name: name.into(),
            unit: "Hz".into(),
            min: 20.0,
            max: 20000.0,
            default: 1000.0,
            param_type,
            syncable: true,
            enum_values: vec!["a".into(), "b".into()],
            is_logarithmic: true,
            skew: 0.5,
            module: "Band 1".into(),
            is_automation_safe: true,
            is_modulatable: false,
        }
    }

    #[test]
    fn playhead_is_one_int() {
        let (addr, tags, args) = wire(EngineStatus::PlayheadUpdate(1920));
        assert_eq!((addr.as_str(), tags.as_str()), ("/status/playhead", "i"));
        assert_eq!(args, vec![OscType::Int(1920)]);
        let (addr, tags, args) = wire(EngineStatus::PlayingStateChanged(true));
        assert_eq!((addr.as_str(), tags.as_str()), ("/status/playing", "i"));
        assert_eq!(args, vec![OscType::Int(1)]);
    }

    #[test]
    fn channel_peaks_are_four_floats_on_the_channel_path() {
        let (addr, tags, args) = wire(EngineStatus::ChannelPeaks {
            id: 7,
            peak_left: 0.5,
            peak_right: 0.25,
            rms_left: 0.125,
            rms_right: 0.0625,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/7/peak", "f f f f")
        );
        assert_eq!(
            args,
            vec![
                OscType::Float(0.5),
                OscType::Float(0.25),
                OscType::Float(0.125),
                OscType::Float(0.0625)
            ]
        );
    }

    #[test]
    fn device_statuses_use_the_device_path_address() {
        let path = DevicePath::root(2);
        let (addr, tags, _) = wire(EngineStatus::DeviceActiveChanged {
            channel_id: 3,
            device_path: path,
            active: false,
        });
        assert_eq!((addr, tags.as_str()), (path.to_osc_addr(3, "active"), "i"));
        assert_eq!(path.to_osc_addr(3, "active"), "/channel/3/device/2/active");
        let (addr, tags, _) = wire(EngineStatus::PluginGuiOpened {
            channel_id: 3,
            device_path: path,
            width: 800,
            height: 600,
            resizable: true,
            floating: false,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/3/device/2/gui/opened", "i i i i")
        );
        let (addr, tags, args) = wire(EngineStatus::PluginGuiClosed {
            channel_id: 3,
            device_path: path,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/3/device/2/gui/closed", "")
        );
        assert!(args.is_empty());
    }

    #[test]
    fn the_modulator_kinds_batch_reports_all_twelve() {
        let statuses = crate::audio::commands::modulator_kind_infos();
        assert_eq!(statuses.len(), 14, "header + 12 kinds + completion");
        assert!(matches!(
            &statuses[0],
            EngineStatus::ModulatorKindsInfo { count } if *count == 12
        ));
        for (i, kind) in crate::audio::modulation::ModulatorKind::ALL
            .iter()
            .enumerate()
        {
            assert!(
                matches!(
                    &statuses[1 + i],
                    EngineStatus::ModulatorKindInfo { id, name, bipolar, params }
                        if id.as_str() == kind.id()
                            && name == kind.name()
                            && *bipolar == kind.bipolar()
                            && params.len() == kind.table().len()
                ),
                "kind {i} ({}) not advertised",
                kind.id()
            );
        }
        assert!(matches!(
            &statuses[13],
            EngineStatus::ModulatorKindsComplete { count } if *count == 12
        ));
    }

    #[test]
    fn modulator_statuses_pin_address_and_types() {
        let path = DevicePath::root(1);
        let (addr, tags, args) = wire(EngineStatus::ModulatorAdded {
            channel_id: 2,
            device_path: path,
            mod_id: 4,
            kind: "lfo".into(),
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/2/device/1/modulator/add", "i s")
        );
        assert_eq!(args, vec![OscType::Int(4), string("lfo")]);
        let (addr, tags, _) = wire(EngineStatus::ModulatorRemoved {
            channel_id: 2,
            device_path: path,
            mod_id: 4,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/2/device/1/modulator/4/remove", "i")
        );
        let (addr, tags, args) = wire(EngineStatus::ModulatorParamChanged {
            channel_id: 2,
            device_path: path,
            mod_id: 4,
            param_id: 9,
            value: 0.75,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/2/device/1/modulator/4/param/9/value", "f")
        );
        assert_eq!(args, vec![OscType::Float(0.75)]);
        let (addr, tags, args) = wire(EngineStatus::ModulatorRouteChanged {
            channel_id: 2,
            device_path: path,
            mod_id: 4,
            target: "param/2".into(),
            amount: -0.5,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/2/device/1/modulator/4/route/set", "s f")
        );
        assert_eq!(args, vec![string("param/2"), OscType::Float(-0.5)]);
        let (addr, tags, _) = wire(EngineStatus::ModulatorsCleared {
            channel_id: 2,
            device_path: path,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/channel/2/device/1/modulator/clear", "")
        );
    }

    #[test]
    fn modulator_kind_info_embeds_typed_parameter_descriptors() {
        let (addr, tags, args) = wire(EngineStatus::ModulatorKindInfo {
            id: "lfo".into(),
            name: "LFO".into(),
            bipolar: true,
            params: vec![param(5, "Rate", ParamType::Enum)],
        });
        assert_eq!(addr, "/builtin/modulator_kind");
        // id name bipolar count, then one descriptor (two enum values):
        // id name unit type syncable min max default log skew enum_count enums.. module auto mod
        assert_eq!(tags, "s s i i i s s s i f f f i f i s s s i i");
        assert_eq!(args[4], OscType::Int(5));
        assert_eq!(args[7], string("enum"));
    }

    #[test]
    fn plugin_parameter_info_packs_flags_and_display_values() {
        let (addr, tags, args) = wire(EngineStatus::PluginParameterInfo {
            channel_id: 1,
            device_path: DevicePath::root(0),
            param_id: 12,
            name: "Cutoff".into(),
            min: 0.0,
            max: 1.0,
            default: 0.5,
            group: "param".into(),
            param_type: ParamType::Float,
            is_hidden: true,
            is_read_only: false,
            is_bypass: true,
            is_modulatable: true,
            module: "".into(),
            enum_values: vec!["x".into()],
            unit: "Hz".into(),
            display: vec![20.0, 20000.0],
        });
        assert_eq!(addr, "/channel/1/device/0/param/info");
        // id name min max default group type flags module enum_count enum.. unit n display..
        assert_eq!(tags, "i s f f f s s i s i s s i f f");
        // hidden (1) + bypass (4) + modulatable (8)
        assert_eq!(args[7], OscType::Int(13));
        assert_eq!(args[6], string("float"));
    }

    #[test]
    fn builtin_device_info_layout() {
        let (addr, tags, args) = wire(EngineStatus::BuiltinDeviceInfo {
            id: "delay".into(),
            name: "Delay".into(),
            category: "effect".into(),
            description: "".into(),
            accepts_midi: false,
            audio_in_channels: 2,
            audio_out_channels: 2,
            supports_file_loading: false,
            file_extensions: vec![],
            file_type_description: "".into(),
            is_container: false,
            parameters: vec![],
            default_modulators: vec![],
            slots: vec![],
        });
        assert_eq!(addr, "/builtin/info");
        // id name category description midi in out files filetype ext_count params container
        // mods slots
        assert_eq!(tags, "s s s s i i i i s i i i i i");
        assert_eq!(args[4], OscType::Int(0));
    }

    #[test]
    fn builtin_device_info_writes_slots_after_default_modulators() {
        let (_, tags, args) = wire(EngineStatus::BuiltinDeviceInfo {
            id: "polysynth".into(),
            name: "PolySynth".into(),
            category: "instrument".into(),
            description: "".into(),
            accepts_midi: true,
            audio_in_channels: 0,
            audio_out_channels: 2,
            supports_file_loading: false,
            file_extensions: vec![],
            file_type_description: "".into(),
            is_container: true,
            parameters: vec![],
            default_modulators: vec![],
            slots: vec![
                ("note_fx".into(), "Note FX".into(), "note".into()),
                ("fx".into(), "FX".into(), "audio".into()),
            ],
        });
        // ... container mods(0) slot_count (key name kind)x2
        assert_eq!(tags, "s s s s i i i i s i i i i i s s s s s s");
        let n = args.len();
        assert_eq!(args[n - 7], OscType::Int(2));
        assert_eq!(
            args[n - 6..],
            [
                string("note_fx"),
                string("Note FX"),
                string("note"),
                string("fx"),
                string("FX"),
                string("audio")
            ]
        );
    }

    #[test]
    fn engine_stats_clamp_counters_to_int32() {
        let (addr, tags, args) = wire(EngineStatus::EngineStats {
            load_avg: 0.25,
            load_peak: 0.5,
            xruns: u64::MAX,
            lock_misses: 3,
            callbacks: 100,
            frames: 256,
            plugin_underruns: 0,
            frames_min: 128,
            frames_max: 256,
            peak_frames: 256,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/status/engine_stats", "f f i i i i i")
        );
        assert_eq!(args[2], OscType::Int(i32::MAX));
    }

    #[test]
    fn render_and_clip_statuses_pin_their_shape() {
        let (addr, tags, _) = wire(EngineStatus::RenderDone {
            job_id: "j".into(),
            outputs: vec!["/tmp/a.wav".into(), "/tmp/b.wav".into()],
        });
        assert_eq!((addr.as_str(), tags.as_str()), ("/render/done", "s s s"));
        let (addr, tags, args) = wire(EngineStatus::ClipLoadStateChanged {
            clip_id: "c1".into(),
            state: ClipLoadState::Loading { req_id: "r".into() },
            source_path: None,
            cache_key: None,
            sample_rate: None,
            channels: None,
        });
        assert_eq!(
            (addr.as_str(), tags.as_str()),
            ("/clip/c1/load_state", "s s s s i i s")
        );
        assert_eq!(args[0], string("loading"));
        assert_eq!(args[1], string("r"));
    }

    #[test]
    fn sfz_key_info_args_layout() {
        use rosc::OscType;
        let args = sfz_key_info_args(
            &[(24, true, "Sustain".into()), (60, false, "Open".into())],
            &[(36, 72), (80, 90)],
        );
        assert_eq!(
            args,
            vec![
                OscType::Int(2),
                OscType::Int(24),
                OscType::Int(1),
                OscType::String("Sustain".into()),
                OscType::Int(60),
                OscType::Int(0),
                OscType::String("Open".into()),
                OscType::Int(2),
                OscType::Int(36),
                OscType::Int(72),
                OscType::Int(80),
                OscType::Int(90),
            ]
        );
        // An empty list is still a message, so Godot clears stale labels and ranges.
        assert_eq!(
            sfz_key_info_args(&[], &[]),
            vec![OscType::Int(0), OscType::Int(0)]
        );
    }

    #[test]
    fn audio_config_reports_zeros_while_no_stream_runs() {
        use crate::audio::commands::AudioConfigReport;
        let args = audio_config_args(AudioConfigReport {
            notice: "No audio output could be opened.".into(),
            ..Default::default()
        });
        assert_eq!(args.len(), 18);
        assert_eq!(args[0], string(""));
        assert_eq!(args[1], OscType::Int(0));
        assert_eq!(args[4], OscType::Int(0));
        assert_eq!(args[12], string("No audio output could be opened."));
        assert_eq!(args[13], string(""), "no running driver");
        assert_eq!(args[14], string("pipewire"), "the requested driver");
        assert_eq!(args[15], string(""));
        assert_eq!(args[16], OscType::Float(0.0));
        assert_eq!(args[17], string("unknown"));
    }

    #[test]
    fn audio_config_tail_names_driver_latency_and_realtime() {
        use crate::audio::commands::AudioConfigReport;
        use crate::audio::pipewire::RealtimeState;
        use crate::audio::stream::{Driver, StreamInfo, StreamRequest};
        let args = audio_config_args(AudioConfigReport {
            active: Some(StreamInfo {
                driver: Driver::PipeWire,
                device: "alsa_output.pci.analog-stereo".into(),
                label: "Ryzen HD Audio Controller Analog Stereo".into(),
                is_default_device: true,
                sample_rate: 48_000,
                period_frames: 1024,
                channels: 2,
            }),
            requested: StreamRequest {
                driver: Driver::PipeWire,
                ..Default::default()
            },
            output_latency_us: 42_667,
            realtime: RealtimeState::Granted,
            ..Default::default()
        });
        assert_eq!(args[0], string("alsa_output.pci.analog-stereo"));
        assert_eq!(args[13], string("pipewire"));
        assert_eq!(args[14], string("pipewire"));
        assert_eq!(args[15], string("Ryzen HD Audio Controller Analog Stereo"));
        assert_eq!(args[16], OscType::Float(42.667));
        assert_eq!(args[17], string("granted"));
    }

    #[test]
    fn audio_device_carries_id_then_label() {
        use crate::audio::stream::OutputDeviceInfo;
        let messages = encode_status(EngineStatus::AudioDeviceInfo(OutputDeviceInfo {
            id: "alsa_output.usb".into(),
            label: "USB Audio".into(),
            is_default: false,
            sample_rates: vec![44_100, 48_000],
            min_period: 32,
            max_period: 2048,
            channels: 2,
        }));
        assert_eq!(messages[0].addr, "/audio/device");
        assert_eq!(
            messages[0].args,
            vec![
                string("alsa_output.usb"),
                string("USB Audio"),
                OscType::Int(0),
                OscType::Int(32),
                OscType::Int(2048),
                OscType::Int(2),
                OscType::Int(44_100),
                OscType::Int(48_000),
            ]
        );
    }
}
