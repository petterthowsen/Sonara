//! Modulator commands: adding, removing and routing modulators, and re-sending them to Godot.

use super::status::BuiltinParamInfo;
use crate::audio::commands::EngineStatus;
use crate::audio::devices::DevicePath;
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;
use crossbeam::channel::Sender;
use tracing::warn;

/// Add a modulator to a device, wrapping the device first when needed.
pub(super) fn add_modulator(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    mod_id: u8,
    kind: String,
    status_tx: &Sender<EngineStatus>,
) -> Option<EngineStatus> {
    let Some(kind) = crate::audio::modulation::ModulatorKind::from_id(&kind) else {
        let message = format!("Unknown modulator kind '{kind}'");
        warn!("{}", message);
        log_engine_error(status_tx, &message);
        return None;
    };
    if let Err(e) = ensure_modulated(state, channel_id, &device_path) {
        warn!("{}", e);
        log_engine_error(status_tx, &e);
        return None;
    }
    let result = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(&device_path))
        .and_then(|device| device.as_modulated_mut())
        .map(|modulated| modulated.add_modulator(mod_id, kind));
    match result {
        Some(Ok(())) => {
            let _ = status_tx.send(EngineStatus::ModulatorAdded {
                channel_id,
                device_path,
                mod_id,
                kind: kind.id().to_string(),
            });
        }
        Some(Err(e)) => {
            warn!("{}", e);
            log_engine_error(status_tx, &e);
            unwrap_if_empty(state, channel_id, &device_path);
        }
        None => {
            let message =
                format!("No device at channel {channel_id} path {device_path} to modulate");
            warn!("{}", message);
            log_engine_error(status_tx, &message);
        }
    }

    None
}

/// Remove a modulator, unwrapping the device when it was the last one.
pub(super) fn remove_modulator(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    mod_id: u8,
    status_tx: &Sender<EngineStatus>,
) {
    let result = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(&device_path))
        .and_then(|device| device.as_modulated_mut())
        .map(|modulated| modulated.remove_modulator(mod_id));
    match result {
        Some(Ok(())) => {
            unwrap_if_empty(state, channel_id, &device_path);
            let _ = status_tx.send(EngineStatus::ModulatorRemoved {
                channel_id,
                device_path,
                mod_id,
            });
        }
        Some(Err(e)) => {
            warn!("{}", e);
            log_engine_error(status_tx, &e);
        }
        None => {
            let message = format!("No modulators at channel {channel_id} path {device_path}");
            warn!("{}", message);
            log_engine_error(status_tx, &message);
        }
    }
}

/// Set a modulator parameter and echo the value it took.
pub(super) fn set_modulator_parameter(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    mod_id: u8,
    param_id: u32,
    value: f32,
    status_tx: &Sender<EngineStatus>,
) {
    let result = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(&device_path))
        .and_then(|device| device.as_modulated_mut())
        .map(|modulated| modulated.set_modulator_param(mod_id, param_id, value));
    match result {
        Some(Ok(value)) => {
            let _ = status_tx.send(EngineStatus::ModulatorParamChanged {
                channel_id,
                device_path,
                mod_id,
                param_id,
                value,
            });
        }
        Some(Err(e)) => {
            warn!("{}", e);
            log_engine_error(status_tx, &e);
        }
        None => {
            let message = format!("No modulators at channel {channel_id} path {device_path}");
            warn!("{}", message);
            log_engine_error(status_tx, &message);
        }
    }
}

/// Route a modulator to a target parameter; a refused route is echoed with amount 0.
pub(super) fn set_modulator_route(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    mod_id: u8,
    target: String,
    amount: f32,
    status_tx: &Sender<EngineStatus>,
) {
    let result = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(&device_path))
        .and_then(|device| device.as_modulated_mut())
        .map(|modulated| modulated.set_modulator_route(mod_id, &target, amount));
    match result {
        Some(Ok(amount)) => {
            let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
                channel_id,
                device_path,
                mod_id,
                target,
                amount,
            });
        }
        // A refused route (unknown or non-modulatable target, no such modulator) is
        // logged and echoed with amount 0, so the UI drops it.
        Some(Err(e)) => {
            warn!("{}", e);
            log_engine_error(status_tx, &e);
            let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
                channel_id,
                device_path,
                mod_id,
                target,
                amount: 0.0,
            });
        }
        None => {
            let message = format!("No modulators at channel {channel_id} path {device_path}");
            warn!("{}", message);
            log_engine_error(status_tx, &message);
            let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
                channel_id,
                device_path,
                mod_id,
                target,
                amount: 0.0,
            });
        }
    }
}

/// Remove every modulator from a device and unwrap it.
pub(super) fn clear_modulators(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    status_tx: &Sender<EngineStatus>,
) -> Option<EngineStatus> {
    let Some(channel) = state.channels.get_mut(&channel_id) else {
        warn!("Channel {} not found for clear modulators", channel_id);
        return None;
    };
    let Some(device) = channel.device_at_path_mut(&device_path) else {
        warn!(
            "Clear modulators for missing device at channel {} path {}",
            channel_id, device_path
        );
        return None;
    };
    if let Some(modulated) = device.as_modulated_mut() {
        modulated.clear_modulators();
    }
    let _ = status_tx.send(EngineStatus::ModulatorsCleared {
        channel_id,
        device_path,
    });
    unwrap_if_empty(state, channel_id, &device_path);

    None
}

/// Wrap the device at `device_path` so it can carry modulators. A no-op when it is already
/// wrapped.
fn ensure_modulated(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: &DevicePath,
) -> Result<(), String> {
    let sample_rate = state.device_sample_rate;
    let channel = state
        .channels
        .get_mut(&channel_id)
        .ok_or_else(|| format!("no channel {channel_id}"))?;
    crate::audio::modulation::wrap_at_path(&mut channel.devices, device_path, sample_rate)
}

/// Drop the modulator wrapper at `device_path` once it holds no modulators.
fn unwrap_if_empty(state: &mut EngineState, channel_id: ChannelId, device_path: &DevicePath) {
    let Some(channel) = state.channels.get_mut(&channel_id) else {
        return;
    };
    let empty = channel
        .device_at_path_mut(device_path)
        .and_then(|device| device.as_modulated_mut())
        .map(|modulated| modulated.modulator_count() == 0)
        .unwrap_or(false);
    if empty {
        let _ = crate::audio::modulation::unwrap_at_path(&mut channel.devices, device_path);
    }
}

/// The modulator kinds the engine offers, as the `/builtin/modulator_*` batch: a header with
/// the count, one info per kind, then a completion.
pub fn modulator_kind_infos() -> Vec<EngineStatus> {
    let kind = crate::audio::modulation::ModulatorKind::COUNT;
    let mut out = Vec::with_capacity(kind + 2);
    out.push(EngineStatus::ModulatorKindsInfo { count: kind });
    for kind in crate::audio::modulation::ModulatorKind::ALL {
        let params = kind
            .table()
            .specs
            .iter()
            .map(|spec| BuiltinParamInfo::from(&spec.info()))
            .collect();
        out.push(EngineStatus::ModulatorKindInfo {
            id: kind.id().to_string(),
            name: kind.name().to_string(),
            bipolar: kind.bipolar(),
            params,
        });
    }
    out.push(EngineStatus::ModulatorKindsComplete { count: kind });
    out
}

/// Re-send a device's modulators after a missed status: `ModulatorsCleared`, then one
/// `ModulatorAdded` per modulator, each of its parameters and each route.
pub(super) fn resend_modulators(
    status_tx: &Sender<EngineStatus>,
    channel_id: ChannelId,
    device_path: &DevicePath,
    device: &mut dyn crate::audio::devices::AudioDevice,
) {
    let Some(modulated) = device.as_modulated_mut() else {
        return;
    };
    if modulated.modulator_count() == 0 {
        return;
    }
    let _ = status_tx.send(EngineStatus::ModulatorsCleared {
        channel_id,
        device_path: *device_path,
    });
    for (mod_id, kind) in modulated.modulator_kinds() {
        let _ = status_tx.send(EngineStatus::ModulatorAdded {
            channel_id,
            device_path: *device_path,
            mod_id,
            kind: kind.id().to_string(),
        });
        for spec in kind.table().specs {
            if let Some(value) = modulated.get_modulator_param(mod_id, spec.id) {
                let _ = status_tx.send(EngineStatus::ModulatorParamChanged {
                    channel_id,
                    device_path: *device_path,
                    mod_id,
                    param_id: spec.id,
                    value,
                });
            }
        }
    }
    for (mod_id, target, amount) in modulated.modulator_routes() {
        let _ = status_tx.send(EngineStatus::ModulatorRouteChanged {
            channel_id,
            device_path: *device_path,
            mod_id,
            target,
            amount,
        });
    }
}

/// Forward a refused modulator command to Godot's `/log` so the UI can show why.
fn log_engine_error(status_tx: &Sender<EngineStatus>, message: &str) {
    let _ = status_tx.send(EngineStatus::LogMessage {
        level: "error".to_string(),
        message: message.to_string(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::commands::{process_command, AudioCommand, EngineStatus};
    use crate::audio::devices::DevicePath;
    use crate::audio::state::EngineState;

    #[test]
    fn modulator_kind_listing_advertises_release() {
        let infos = modulator_kind_infos();
        assert!(matches!(
            infos.first(),
            Some(EngineStatus::ModulatorKindsInfo { count: 7 })
        ));
        let release = infos.iter().find_map(|info| match info {
            EngineStatus::ModulatorKindInfo {
                id,
                name,
                bipolar,
                params,
            } if id == "release" => Some((name.clone(), *bipolar, params.len())),
            _ => None,
        });
        assert_eq!(release, Some(("Release".to_string(), false, 0)));
    }

    /// Channel 2 with one Filter effect, the modulatable target the tests route into.
    fn modulator_test_state(status_tx: &Sender<EngineStatus>) -> EngineState {
        let mut state = EngineState::default();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            status_tx,
        );
        state.channels.get_mut(&2).unwrap().devices.push(
            crate::audio::devices::create_effect("sonara.builtin.filter", 48_000.0, 512)
                .expect("filter effect"),
        );
        state
    }

    fn modulator_count(state: &mut EngineState) -> usize {
        state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .map(|modulated| modulated.modulator_count())
            .unwrap_or(0)
    }

    #[test]
    fn modulator_commands_wrap_and_echo() {
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        let mut state = modulator_test_state(&status_tx);
        while status_rx.try_recv().is_ok() {}
        let path = DevicePath::root(0);

        process_command(
            &mut state,
            AudioCommand::AddModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                kind: "lfo".to_string(),
            },
            128,
            &status_tx,
        );
        assert_eq!(modulator_count(&mut state), 1, "the device is wrapped");
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorAdded { mod_id: 0, kind, .. }) if kind == "lfo"
        ));

        // LFO Rate (id 10) lands at the requested normalized value.
        process_command(
            &mut state,
            AudioCommand::SetModulatorParameter {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                param_id: 10,
                value: 0.75,
            },
            128,
            &status_tx,
        );
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorParamChanged { param_id: 10, value, .. })
                if (value - 0.75).abs() < 1e-6
        ));

        // Route to Filter Cutoff (id 2); amounts clamp and the echo carries the applied value.
        process_command(
            &mut state,
            AudioCommand::SetModulatorRoute {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                target: "param/2".to_string(),
                amount: 4.0,
            },
            128,
            &status_tx,
        );
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorRouteChanged { target, amount, .. })
                if target == "param/2" && amount == 1.0
        ));
        assert!(state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .unwrap()
            .modulator_routes()
            .iter()
            .any(|(_, target, amount)| target == "param/2" && *amount == 1.0));

        // An unknown target is refused: a `/log` error and an echo with amount 0.
        process_command(
            &mut state,
            AudioCommand::SetModulatorRoute {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                target: "param/99".to_string(),
                amount: 0.5,
            },
            128,
            &status_tx,
        );
        let refused: Vec<_> = status_rx.try_iter().collect();
        assert!(refused
            .iter()
            .any(|s| matches!(s, EngineStatus::LogMessage { level, .. } if level == "error")));
        assert!(refused.iter().any(|s| matches!(
            s,
            EngineStatus::ModulatorRouteChanged { target, amount, .. }
                if target == "param/99" && *amount == 0.0
        )));

        // Removing the last modulator unwraps the device.
        process_command(
            &mut state,
            AudioCommand::RemoveModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
            },
            128,
            &status_tx,
        );
        assert_eq!(modulator_count(&mut state), 0);
        assert!(state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .is_none());
    }

    #[test]
    fn clear_modulators_unwraps() {
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        let mut state = modulator_test_state(&status_tx);
        let path = DevicePath::root(0);
        process_command(
            &mut state,
            AudioCommand::AddModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                kind: "ad".to_string(),
            },
            128,
            &status_tx,
        );
        while status_rx.try_recv().is_ok() {}
        process_command(
            &mut state,
            AudioCommand::ClearModulators {
                channel_id: 2,
                device_path: path,
            },
            128,
            &status_tx,
        );
        assert!(matches!(
            status_rx.try_recv(),
            Ok(EngineStatus::ModulatorsCleared { .. })
        ));
        assert!(state.channels.get_mut(&2).unwrap().devices[0]
            .as_modulated_mut()
            .is_none());
    }

    #[test]
    fn get_device_state_resends_modulators() {
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        let mut state = modulator_test_state(&status_tx);
        let path = DevicePath::root(0);
        process_command(
            &mut state,
            AudioCommand::AddModulator {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                kind: "lfo".to_string(),
            },
            128,
            &status_tx,
        );
        process_command(
            &mut state,
            AudioCommand::SetModulatorRoute {
                channel_id: 2,
                device_path: path,
                mod_id: 0,
                target: "param/2".to_string(),
                amount: 0.5,
            },
            128,
            &status_tx,
        );
        let (get_tx, get_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::GetDeviceState {
                channel_id: 2,
                device_path: path,
            },
            128,
            &get_tx,
        );
        let replies: Vec<_> = get_rx.try_iter().collect();
        assert!(matches!(replies[0], EngineStatus::ModulatorsCleared { .. }));
        assert!(replies.iter().any(|s| matches!(
            s,
            EngineStatus::ModulatorAdded { mod_id: 0, kind, .. } if kind == "lfo"
        )));
        assert!(replies
            .iter()
            .any(|s| matches!(s, EngineStatus::ModulatorParamChanged { param_id: 10, .. })));
        assert!(replies.iter().any(|s| matches!(
            s,
            EngineStatus::ModulatorRouteChanged { target, amount: 0.5, .. }
                if target == "param/2"
        )));
    }
}
