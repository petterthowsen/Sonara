//! Device commands that apply to any device: moving, parameters, activation, auditioning, and the
//! parameter lists and state replies Godot asks for.

use super::modulation::resend_modulators;
use crate::audio::commands::EngineStatus;
use crate::audio::devices::DevicePath;
use crate::audio::midi_types::{NoteEvent, AUDITION_NOTE_ID};
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;
use crossbeam::channel::Sender;
use tracing::{info, warn};

/// Move a device within its chain, releasing the notes of note effects whose downstream changes.
pub(super) fn move_device(
    state: &mut EngineState,
    channel_id: ChannelId,
    parent_path: DevicePath,
    from_position: usize,
    to_position: usize,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        // Moving changes which devices sit after each note effect.
        channel.release_note_effects_in(&parent_path);
        match crate::audio::devices::container::move_device(
            &mut channel.devices,
            &parent_path,
            from_position,
            to_position,
        ) {
            Ok(()) => info!(
                "Device moved in channel {} parent {} from {} to {}",
                channel_id, parent_path, from_position, to_position
            ),
            Err(e) => warn!("{}", e),
        }
    } else {
        warn!("Channel {} not found for move device", channel_id);
    }
}

/// Set a device parameter from a normalized or index value and echo the normalized result.
pub(super) fn set_device_parameter(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    param_id: u32,
    value: crate::audio::types::ParamSetValue,
    status_tx: &Sender<EngineStatus>,
) -> Option<EngineStatus> {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        let Some(device) = channel.device_at_path_mut(&device_path) else {
            warn!(
                "Invalid device path {} for channel {}",
                device_path, channel_id
            );
            return None;
        };
        let params = device.parameters();
        let mut normalized: f32 = 0.0;
        if let Some(info) = params.iter().find(|p| p.id == param_id) {
            match value {
                crate::audio::types::ParamSetValue::Normalized(v) => {
                    normalized = v.clamp(0.0, 1.0);
                }
                crate::audio::types::ParamSetValue::Index(idx) => match info.param_type {
                    crate::audio::devices::ParamType::Bool => {
                        normalized = if idx <= 0 { 0.0 } else { 1.0 };
                    }
                    crate::audio::devices::ParamType::Enum => {
                        let n = info.enum_values.len();
                        if n > 1 {
                            let i = idx.max(0) as usize;
                            let i = i.min(n - 1);
                            normalized = (i as f32) / ((n - 1) as f32);
                        } else {
                            normalized = 0.0;
                        }
                    }
                    crate::audio::devices::ParamType::Float => {
                        normalized = if idx <= 0 { 0.0 } else { 1.0 };
                    }
                },
            }
        } else if let crate::audio::types::ParamSetValue::Normalized(v) = value {
            normalized = v.clamp(0.0, 1.0);
        }

        device.set_parameter(param_id, normalized);
        info!(
            "Device parameter set: channel={} device={} param={} value={}",
            channel_id, device_path, param_id, normalized
        );
        let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
            channel_id,
            device_path,
            param_id,
            value: normalized,
        });
    } else {
        warn!("Channel {} not found for set device parameter", channel_id);
    }

    None
}

/// Activate or deactivate a device and report the change.
pub(super) fn set_device_active(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    active: bool,
    status_tx: &Sender<EngineStatus>,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if active && !device.is_active() {
                match device.activate() {
                    Ok(_) => {
                        info!(
                            "Device activated: channel={} device={}",
                            channel_id, device_path
                        );
                        let _ = status_tx.send(EngineStatus::DeviceActiveChanged {
                            channel_id,
                            device_path,
                            active: true,
                        });
                    }
                    Err(e) => {
                        warn!(
                            "Failed to activate device at channel {} path {}: {}",
                            channel_id, device_path, e
                        );
                    }
                }
            } else if !active && device.is_active() {
                match device.deactivate() {
                    Ok(_) => {
                        info!(
                            "Device deactivated: channel={} device={}",
                            channel_id, device_path
                        );
                        let _ = status_tx.send(EngineStatus::DeviceActiveChanged {
                            channel_id,
                            device_path,
                            active: false,
                        });
                    }
                    Err(e) => {
                        warn!(
                            "Failed to deactivate device at channel {} path {}: {}",
                            channel_id, device_path, e
                        );
                    }
                }
            }
        } else {
            warn!(
                "Device not found at channel {} path {}",
                channel_id, device_path
            );
        }
    } else {
        warn!("Channel {} not found for set device active", channel_id);
    }
}

/// Enable or bypass a device and report the change.
pub(super) fn set_device_enabled(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    enabled: bool,
    status_tx: &Sender<EngineStatus>,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            device.set_enabled(enabled);
            info!(
                "Device set to {}: channel={} device={}",
                if enabled { "enabled" } else { "bypassed" },
                channel_id,
                device_path
            );
            let _ = status_tx.send(EngineStatus::DeviceEnabledChanged {
                channel_id,
                device_path,
                enabled,
            });
        } else {
            warn!(
                "Device not found at channel {} path {}",
                channel_id, device_path
            );
        }
    } else {
        warn!("Channel {} not found for set device enabled", channel_id);
    }
}

/// Start loading an SFZ file into an SFZ device.
pub(super) fn load_device_file(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    file_path: String,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if let Some(sfizz_device) = device
                .as_any_mut()
                .downcast_mut::<crate::audio::devices::SfizzDevice>()
            {
                info!(
                    "Loading SFZ file into device: channel={} device={} path={}",
                    channel_id, device_path, file_path
                );
                sfizz_device.load_sfz_async(std::path::PathBuf::from(file_path));
            } else {
                warn!(
                    "Device at channel {} path {} does not support file loading",
                    channel_id, device_path
                );
            }
        } else {
            warn!(
                "Device not found at channel {} path {}",
                channel_id, device_path
            );
        }
    } else {
        warn!("Channel {} not found for load device file", channel_id);
    }
}

/// Send an audition note-on or note-off straight to a device.
pub(super) fn audition_device(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    note: u8,
    velocity: u8,
    is_note_on: bool,
) -> Option<EngineStatus> {
    let Some(device) = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(&device_path))
    else {
        warn!("No device at channel {} path {}", channel_id, device_path);
        return None;
    };
    let event = if is_note_on && velocity > 0 {
        NoteEvent::On {
            note_id: AUDITION_NOTE_ID,
            key: note,
            velocity: velocity as f32 / 127.0,
        }
    } else {
        NoteEvent::Off {
            note_id: AUDITION_NOTE_ID,
            key: note,
            release: crate::audio::midi_types::DEFAULT_RELEASE,
        }
    };
    device.mark_activity();
    device.send_note_event(&event, 0);

    None
}

/// Send a device's parameter list to Godot.
pub(super) fn get_plugin_parameters(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    status_tx: &Sender<EngineStatus>,
) {
    if let Some(channel) = state.channels.get(&channel_id) {
        if let Some(device) = channel.device_at_path(&device_path) {
            let params = device.parameters();
            info!(
                "Querying {} parameters for device at channel {} path {}",
                params.len(),
                channel_id,
                device_path
            );
            send_parameter_list(status_tx, channel_id, device_path, device, params);
        } else {
            warn!(
                "Device not found at channel {} path {}",
                channel_id, device_path
            );
        }
    } else {
        warn!("Channel {} not found for get plugin parameters", channel_id);
    }
}

/// Re-send what Godot cannot recompute about a device after a missed status: loading state, parameter list, zone states and modulators.
pub(super) fn get_device_state(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    status_tx: &Sender<EngineStatus>,
) -> Option<EngineStatus> {
    // Godot missed a status (UDP drops under load): re-send what it can't recompute.
    let Some(device) = state
        .channels
        .get(&channel_id)
        .and_then(|channel| channel.device_at_path(&device_path))
    else {
        warn!(
            "Device state requested for missing device at channel {} path {}",
            channel_id, device_path
        );
        return None;
    };
    if let Some(loading_state) = device.loading_state() {
        let _ = status_tx.send(EngineStatus::DeviceLoadingStateChanged {
            channel_id,
            device_path,
            state: loading_state,
        });
    }
    if device.has_dynamic_parameters() {
        let params = device.parameters();
        // Still loading: the list follows the load, as it normally does.
        if !params.is_empty() {
            send_parameter_list(status_tx, channel_id, device_path, device, params);
        }
    }
    // Modulators live in the wrapper, not in the parameters: resend them as clear +
    // adds. The immutable borrow above ends here so we can reach the wrapper.
    if let Some(device) = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(&device_path))
    {
        if let Some(sampler) = device
            .as_any_mut()
            .downcast_mut::<crate::audio::devices::SamplerDevice>()
        {
            sampler.resend_zone_states();
        }
        resend_modulators(status_tx, channel_id, &device_path, device);
    }

    None
}

/// A plugin finished (re)loading: re-send its parameters, modulation offsets and restored values.
pub(super) fn device_ready(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    restored_values: Vec<(u32, f32)>,
    status_tx: &Sender<EngineStatus>,
) {
    info!(
        "Device ready notification for channel {} path {}, re-sending parameters",
        channel_id, device_path
    );
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if let Some(subprocess_device) = device
                .as_any_mut()
                .downcast_mut::<crate::audio::devices::clap_host::SubprocessClapAdapter>(
            ) {
                subprocess_device.on_device_ready();
                for &(param_id, value) in &restored_values {
                    subprocess_device.cache_parameter_value(param_id, value);
                }
            }
            // A fresh plugin has no modulation offsets; push the current ones again
            // (spec 018 Phase 5).
            if let Some(modulated) = device.as_modulated_mut() {
                modulated.resend_offsets();
            }
            let params = device.parameters();
            if !params.is_empty() {
                send_parameter_list(status_tx, channel_id, device_path, device, params);
            }
            // After the parameter list, so Godot doesn't reset them to defaults.
            for (param_id, value) in restored_values {
                let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                    channel_id,
                    device_path,
                    param_id,
                    value,
                });
            }
        }
    }
}

/// Send `params` (from `device.parameters()`) to Godot: `param/count`, then one `param/info` each.
fn send_parameter_list(
    status_tx: &Sender<EngineStatus>,
    channel_id: ChannelId,
    device_path: DevicePath,
    device: &dyn crate::audio::devices::AudioDevice,
    params: Vec<crate::audio::devices::ParamInfo>,
) {
    let _ = status_tx.send(EngineStatus::PluginParameterCount {
        channel_id,
        device_path,
        count: params.len(),
    });
    for param in params {
        let _ = status_tx.send(EngineStatus::PluginParameterInfo {
            channel_id,
            device_path,
            param_id: param.id,
            name: param.name,
            min: param.min,
            max: param.max,
            default: param.default,
            group: device.parameter_group(param.id).to_string(),
            param_type: param.param_type,
            is_hidden: param.is_hidden,
            is_read_only: param.is_read_only,
            is_bypass: param.is_bypass,
            is_modulatable: param.is_modulatable,
            module: param.module,
            enum_values: param.enum_values,
            unit: param.unit,
            display: param.display,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::commands::{process_command, AudioCommand, EngineStatus};
    use crate::audio::devices::DevicePath;
    use crate::audio::state::EngineState;

    #[test]
    fn moving_instrument_across_note_effect_releases() {
        use crate::audio::devices::note_fx::host::tests::test_host;
        use crate::audio::devices::note_fx::routing::test_devices::Recorder;
        let mut state = EngineState::default();
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            &status_tx,
        );
        let (recorder, log) = Recorder::new();
        {
            let channel = state.channels.get_mut(&2).unwrap();
            channel.devices.push(Box::new(test_host(12.0, 0.0, 0.0)));
            channel.devices.push(Box::new(recorder));
            channel.send_note_event_to_devices(&NoteEvent::test_on(60, 100), 0);
            channel.dispatch_notes(64);
        }
        process_command(
            &mut state,
            AudioCommand::MoveDevice {
                channel_id: 2,
                parent_path: DevicePath::default(),
                from_position: 1,
                to_position: 0,
            },
            128,
            &status_tx,
        );
        let events: Vec<NoteEvent> = log.lock().unwrap().iter().map(|(_, e)| *e).collect();
        assert_eq!(events.len(), 2, "{events:?}");
        assert!(matches!(events[1], NoteEvent::Off { key: 72, .. }));
    }

    /// A channel 2 whose only device is `device`, plus the status receiver for `GetDeviceState`.
    fn device_state_replies(
        device: Box<dyn crate::audio::devices::AudioDevice>,
    ) -> Vec<EngineStatus> {
        let mut state = EngineState::default();
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            &status_tx,
        );
        state.channels.get_mut(&2).unwrap().devices.push(device);
        while status_rx.try_recv().is_ok() {}
        process_command(
            &mut state,
            AudioCommand::GetDeviceState {
                channel_id: 2,
                device_path: DevicePath::root(0),
            },
            128,
            &status_tx,
        );
        status_rx.try_iter().collect()
    }

    #[test]
    fn get_device_state_resends_loading_state() {
        let mut sampler = crate::audio::devices::SamplerDevice::new_for_metadata();
        sampler.begin_sample_load("req".to_string());
        let replies = device_state_replies(Box::new(sampler));
        assert_eq!(replies.len(), 1);
        assert!(matches!(
            &replies[0],
            EngineStatus::DeviceLoadingStateChanged { channel_id: 2, state, .. } if state == "loading"
        ));
    }

    #[test]
    fn get_device_state_skips_empty_dynamic_parameter_list() {
        // An SFZ device with nothing loaded has no parameters to advertise yet.
        let sfizz = crate::audio::devices::SfizzDevice::new_for_metadata(48_000.0);
        let replies = device_state_replies(Box::new(sfizz));
        assert_eq!(replies.len(), 1);
        assert!(matches!(
            &replies[0],
            EngineStatus::DeviceLoadingStateChanged { state, .. } if state == "idle"
        ));
    }

    #[test]
    fn get_device_state_is_silent_for_fixed_devices() {
        let delay = crate::audio::devices::DelayDevice::new(48_000.0, 5000.0);
        assert!(device_state_replies(Box::new(delay)).is_empty());
    }
}
