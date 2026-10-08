//! Engine statuses as OSC messages for Godot. Addresses, argument order and OSC types are part of
//! the protocol (`docs/subsystems/osc-protocol.md`); Godot depends on them.

use rosc::{OscMessage, OscPacket, OscType};
use std::net::{SocketAddr, UdpSocket};
use tracing::{info, warn};

use super::server::OscServer;
use crate::audio::clip::ClipLoadState;
use crate::audio::commands::BuiltinParamInfo;
use crate::audio::EngineStatus;

impl OscServer {
    /// Send a status update to the client
    pub(super) fn send_status_update(socket: &UdpSocket, client_port: u16, status: EngineStatus) {
        let is_param_change = status.is_param_change();
        let (addr, args) = match status {
            EngineStatus::PlayheadUpdate(ticks) => (
                "/status/playhead".to_string(),
                vec![OscType::Int(ticks as i32)],
            ),
            EngineStatus::PlayingStateChanged(playing) => (
                "/status/playing".to_string(),
                vec![OscType::Int(if playing { 1 } else { 0 })],
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
                    ClipLoadState::Unloaded => {
                        ("unloaded".to_string(), String::new(), String::new())
                    }
                    ClipLoadState::Loading { req_id } => {
                        ("loading".to_string(), req_id, String::new())
                    }
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
            } => {
                tracing::info!("📨 Sending plugin info: {} ({})", name, id);
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

                ("/builtin/info".to_string(), args)
            }
            EngineStatus::BuiltinDevicesComplete { count } => (
                "/builtin/complete".to_string(),
                vec![OscType::Int(count as i32)],
            ),
            EngineStatus::AudioDeviceInfo(device) => {
                let mut args = vec![
                    OscType::String(device.name),
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
                let addr =
                    device_path.to_osc_addr(channel_id, &format!("param/{}/value", param_id));
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

        let msg = OscMessage { addr, args };

        let packet = OscPacket::Message(msg);
        if let Ok(buf) = rosc::encoder::encode(&packet) {
            let client_addr = format!("127.0.0.1:{}", client_port);
            if let Ok(addr) = client_addr.parse::<SocketAddr>() {
                match socket.send_to(&buf, addr) {
                    Ok(bytes) => {
                        // Only log param changes for debugging
                        if is_param_change {
                            info!("📡 OSC sent: {} bytes to {}", bytes, addr);
                        }
                    }
                    Err(e) => warn!("Failed to send OSC: {}", e),
                }
            }
        }
    }
}

/// `/audio/config` arguments: the running stream (device "" and zeros when none could be
/// opened), then the request, the PipeWire graph and the two warning texts.
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
    use crate::osc::parse::test_support::string;

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
        assert_eq!(args.len(), 13);
        assert_eq!(args[0], string(""));
        assert_eq!(args[1], OscType::Int(0));
        assert_eq!(args[4], OscType::Int(0));
        assert_eq!(args[12], string("No audio output could be opened."));
    }
}
