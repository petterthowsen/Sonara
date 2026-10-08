//! Device routes: `/channel/{id}/device/{path}/...` and the channel-level device chain edits.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::{info, warn};

use crate::audio::devices::DevicePath;
use crate::audio::AudioCommand;
use crate::osc::audio_files::{generate_device_request_id, is_audio_sample_path};
use crate::osc::gui::parse_embed_args;
use crate::osc::parse::osc_int;
use crate::osc::server::OscServer;
use crate::window_manager::WindowManager;

impl OscServer {
    /// Dispatch `/channel/{id}/device/{path}/...` commands (nested `child` segments allowed).
    pub(super) fn handle_device_message(
        &self,
        channel_id: usize,
        device_path: DevicePath,
        action: &[String],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        let action_refs: Vec<&str> = action.iter().map(|s| s.as_str()).collect();
        match action_refs.as_slice() {
            ["activate"] => {
                if let Some(OscType::Int(active)) = args.first() {
                    command_tx.send(AudioCommand::SetDeviceActive {
                        channel_id,
                        device_path,
                        active: *active != 0,
                    })?;
                }
            }
            ["enable"] => {
                if let Some(OscType::Int(enabled)) = args.first() {
                    command_tx.send(AudioCommand::SetDeviceEnabled {
                        channel_id,
                        device_path,
                        enabled: *enabled != 0,
                    })?;
                }
            }
            ["load_file"] => {
                if let Some(OscType::String(file_path)) = args.first() {
                    if is_audio_sample_path(file_path) {
                        let req_id = match args.get(1) {
                            Some(OscType::String(id)) if !id.is_empty() => id.clone(),
                            _ => generate_device_request_id(channel_id, &device_path),
                        };
                        self.begin_device_sample_load(
                            channel_id,
                            device_path,
                            None,
                            file_path.clone(),
                            req_id,
                            command_tx,
                        )?;
                    } else {
                        command_tx.send(AudioCommand::LoadDeviceFile {
                            channel_id,
                            device_path,
                            file_path: file_path.clone(),
                        })?;
                    }
                }
            }
            // Optional `parent_xid x y w h`: embed the host window before it is first mapped
            ["gui", "open"] => {
                let process_key = device_path.to_window_key(channel_id);
                let embed = if args.is_empty() {
                    None
                } else {
                    let embed = parse_embed_args(args, true);
                    if embed.is_none() {
                        warn!(
                            "gui/open: expected parent_xid x y w h, got {:?}; opening floating",
                            args
                        );
                    }
                    embed
                };
                let window_handle = window_manager.create_window(process_key, 800, 600, embed);
                if let (Some(_), Some((parent_xid, _))) = (window_handle, embed) {
                    self.send_gui_embedded(channel_id, &device_path, parent_xid);
                }
                command_tx.send(AudioCommand::OpenPluginGui {
                    channel_id,
                    device_path,
                    window_handle,
                })?;
            }
            // Embed the plugin's host window into a Godot window (ADR 0016)
            ["gui", "embed"] => {
                let process_key = device_path.to_window_key(channel_id);
                match parse_embed_args(args, true) {
                    Some((parent_xid, rect)) => {
                        if window_manager.embed_window(&process_key, parent_xid, rect) {
                            self.send_gui_embedded(channel_id, &device_path, parent_xid);
                        }
                    }
                    None => warn!(
                        "gui/embed: expected parent_xid x y w h [scroll_x scroll_y], got {:?}",
                        args
                    ),
                }
            }
            ["gui", "bounds"] => {
                let process_key = device_path.to_window_key(channel_id);
                match parse_embed_args(args, false) {
                    Some((_, rect)) => window_manager.set_embed_bounds(&process_key, rect),
                    None => warn!(
                        "gui/bounds: expected x y w h [scroll_x scroll_y], got {:?}",
                        args
                    ),
                }
            }
            ["gui", "unembed"] => {
                let process_key = device_path.to_window_key(channel_id);
                if window_manager.unembed_window(&process_key) {
                    self.send_gui_embedded(channel_id, &device_path, 0);
                }
            }
            ["gui", "visible"] => match args.first().and_then(osc_int) {
                Some(visible) => {
                    let visible = visible != 0;
                    let process_key = device_path.to_window_key(channel_id);
                    window_manager.set_window_visible(&process_key, visible);
                    command_tx.send(AudioCommand::SetPluginGuiVisible {
                        channel_id,
                        device_path,
                        visible,
                    })?;
                }
                None => warn!("gui/visible: expected visible:i, got {:?}", args),
            },
            ["gui", "size"] => match (
                args.first().and_then(osc_int),
                args.get(1).and_then(osc_int),
            ) {
                (Some(width), Some(height)) if width > 0 && height > 0 => {
                    command_tx.send(AudioCommand::SetPluginGuiSize {
                        channel_id,
                        device_path,
                        width: width as u32,
                        height: height as u32,
                    })?;
                }
                _ => warn!("gui/size: expected w:i h:i (positive), got {:?}", args),
            },
            ["gui", "close"] => {
                // Hide the host window and take it out of the Godot window first, so Godot can
                // free its window at once. It is destroyed once the plugin confirms the close.
                let process_key = device_path.to_window_key(channel_id);
                if window_manager.release_window(&process_key) {
                    self.send_gui_embedded(channel_id, &device_path, 0);
                }
                command_tx.send(AudioCommand::ClosePluginGui {
                    channel_id,
                    device_path,
                })?;
            }
            ["param", param_id_str] => {
                if let Ok(param_id) = param_id_str.parse::<u32>() {
                    match args.first() {
                        Some(OscType::Float(v)) => {
                            command_tx.send(AudioCommand::SetDeviceParameter {
                                channel_id,
                                device_path,
                                param_id,
                                value: crate::audio::types::ParamSetValue::Normalized(*v),
                            })?;
                        }
                        Some(OscType::Int(i)) => {
                            command_tx.send(AudioCommand::SetDeviceParameter {
                                channel_id,
                                device_path,
                                param_id,
                                value: crate::audio::types::ParamSetValue::Index(*i),
                            })?;
                        }
                        _ => {}
                    }
                }
            }
            ["modulator", ..] => {
                if let Some(cmd) =
                    parse_modulator_command(channel_id, device_path, &action_refs, args)
                {
                    command_tx.send(cmd)?;
                }
            }
            ["data", "subscribe"] => {
                if let Some(OscType::String(data_type)) = args.first() {
                    command_tx.send(AudioCommand::SubscribeDeviceData {
                        channel_id,
                        device_path,
                        data_type: data_type.clone(),
                    })?;
                }
            }
            ["data", "unsubscribe"] => {
                if let Some(OscType::String(data_type)) = args.first() {
                    command_tx.send(AudioCommand::UnsubscribeDeviceData {
                        channel_id,
                        device_path,
                        data_type: data_type.clone(),
                    })?;
                }
            }
            ["data", "configure"] => {
                let value = match args.get(2) {
                    Some(OscType::Float(v)) => Some(*v),
                    Some(OscType::Int(v)) => Some(*v as f32),
                    Some(OscType::Double(v)) => Some(*v as f32),
                    _ => None,
                };
                if let (Some(OscType::String(data_type)), Some(OscType::String(key)), Some(value)) =
                    (args.first(), args.get(1), value)
                {
                    command_tx.send(AudioCommand::ConfigureDeviceData {
                        channel_id,
                        device_path,
                        data_type: data_type.clone(),
                        key: key.clone(),
                        value,
                    })?;
                } else {
                    warn!(
                        "/data/configure expects [s:data_type, s:key, f:value]: {:?}",
                        args
                    );
                }
            }
            ["add_device"] => {
                if let Some(cmd) = parse_add_device_command(channel_id, device_path, args) {
                    command_tx.send(cmd)?;
                }
            }
            ["remove_device"] => {
                if let Some(OscType::Int(position)) = args.first() {
                    command_tx.send(AudioCommand::RemoveDeviceFromChannel {
                        channel_id,
                        parent_path: device_path,
                        position: *position as usize,
                    })?;
                }
            }
            ["move_device"] => {
                if let (Some(OscType::Int(from_pos)), Some(OscType::Int(to_pos))) =
                    (args.get(0), args.get(1))
                {
                    command_tx.send(AudioCommand::MoveDevice {
                        channel_id,
                        parent_path: device_path,
                        from_position: *from_pos as usize,
                        to_position: *to_pos as usize,
                    })?;
                }
            }
            ["get_parameters"] => {
                command_tx.send(AudioCommand::GetPluginParameters {
                    channel_id,
                    device_path,
                })?;
            }
            ["state", "get"] => {
                command_tx.send(AudioCommand::GetDeviceState {
                    channel_id,
                    device_path,
                })?;
            }
            ["state", "save"] => {
                if let Some(OscType::String(file_path)) = args.first() {
                    command_tx.send(AudioCommand::SavePluginState {
                        channel_id,
                        device_path,
                        file_path: file_path.clone(),
                    })?;
                }
            }
            ["state", "load"] => {
                if let Some(OscType::String(file_path)) = args.first() {
                    command_tx.send(AudioCommand::LoadPluginState {
                        channel_id,
                        device_path,
                        file_path: file_path.clone(),
                    })?;
                }
            }
            // Reload a crashed plugin: respawn its host and restore its state (Phase 4).
            ["reload"] => {
                command_tx.send(AudioCommand::ReloadDevice {
                    channel_id,
                    device_path,
                })?;
            }
            _ => {
                if !self.route_device_slots(
                    channel_id,
                    device_path,
                    &action_refs,
                    args,
                    command_tx,
                )? {
                    warn!(
                        "Unhandled device OSC action {:?} on channel {} path {}",
                        action, channel_id, device_path
                    );
                }
            }
        }
        Ok(())
    }

    /// Handle the channel-level device chain edits (`add_device`, `remove_device`, `move_device`,
    /// `clear_devices`). Returns false for an address this area doesn't know.
    pub(super) fn route_channel_devices(
        &self,
        parts: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
    ) -> Result<bool> {
        match parts {
            // Device management - path-based: /channel/{id}/add_device
            ["channel", channel_id_str, "add_device"] => {
                if let (
                    Ok(channel_id),
                    Some(OscType::String(device_id)),
                    Some(OscType::Int(position)),
                ) = (channel_id_str.parse::<usize>(), args.get(0), args.get(1))
                {
                    // Optional active and enabled parameters (default to true if not provided)
                    let active = args
                        .get(2)
                        .and_then(|arg| {
                            if let OscType::Int(v) = arg {
                                Some(*v != 0)
                            } else {
                                None
                            }
                        })
                        .unwrap_or(true);
                    let enabled = args
                        .get(3)
                        .and_then(|arg| {
                            if let OscType::Int(v) = arg {
                                Some(*v != 0)
                            } else {
                                None
                            }
                        })
                        .unwrap_or(true);
                    // Device type parameter (builtin, clap, lv2, vst3)
                    let device_type = args
                        .get(4)
                        .and_then(|arg| {
                            if let OscType::String(t) = arg {
                                Some(t.clone())
                            } else {
                                None
                            }
                        })
                        .unwrap_or_else(|| "builtin".to_string());
                    // Device file parameter (path to plugin, empty for built-ins)
                    let device_file = args
                        .get(5)
                        .and_then(|arg| {
                            if let OscType::String(f) = arg {
                                Some(f.clone())
                            } else {
                                None
                            }
                        })
                        .unwrap_or_default();

                    info!("Add device {} (type={}) to channel {} at position {} [active={}, enabled={}]", 
                        device_id, device_type, channel_id, position, active, enabled);
                    command_tx.send(AudioCommand::AddDeviceToChannel {
                        channel_id,
                        parent_path: DevicePath::default(),
                        device_id: device_id.clone(),
                        device_type,
                        device_file,
                        position: *position,
                        active,
                        enabled,
                    })?;
                }
            }
            ["channel", channel_id_str, "remove_device"] => {
                if let (Ok(channel_id), Some(OscType::Int(position))) =
                    (channel_id_str.parse::<usize>(), args.first())
                {
                    info!(
                        "Remove device from channel {} at position {}",
                        channel_id, position
                    );
                    command_tx.send(AudioCommand::RemoveDeviceFromChannel {
                        channel_id,
                        parent_path: DevicePath::default(),
                        position: *position as usize,
                    })?;
                }
            }
            ["channel", channel_id_str, "move_device"] => {
                if let (Ok(channel_id), Some(OscType::Int(from_pos)), Some(OscType::Int(to_pos))) =
                    (channel_id_str.parse::<usize>(), args.get(0), args.get(1))
                {
                    info!(
                        "Move device in channel {} from position {} to position {}",
                        channel_id, from_pos, to_pos
                    );
                    command_tx.send(AudioCommand::MoveDevice {
                        channel_id,
                        parent_path: DevicePath::default(),
                        from_position: *from_pos as usize,
                        to_position: *to_pos as usize,
                    })?;
                }
            }
            ["channel", channel_id_str, "clear_devices"] => {
                if let Ok(channel_id) = channel_id_str.parse::<usize>() {
                    info!("Clear all devices from channel {}", channel_id);
                    command_tx.send(AudioCommand::ClearChannelDevices { channel_id })?;
                }
            }

            _ => return Ok(false),
        }
        Ok(true)
    }
}

/// Parse `/add_device` arguments shared by channel-root and nested container paths.
fn parse_add_device_command(
    channel_id: usize,
    parent_path: DevicePath,
    args: &[OscType],
) -> Option<AudioCommand> {
    let device_id = match args.first() {
        Some(OscType::String(s)) => s.clone(),
        _ => return None,
    };
    let position = match args.get(1) {
        Some(OscType::Int(p)) => *p,
        _ => return None,
    };
    let active = args
        .get(2)
        .and_then(|arg| {
            if let OscType::Int(v) = arg {
                Some(*v != 0)
            } else {
                None
            }
        })
        .unwrap_or(true);
    let enabled = args
        .get(3)
        .and_then(|arg| {
            if let OscType::Int(v) = arg {
                Some(*v != 0)
            } else {
                None
            }
        })
        .unwrap_or(true);
    let device_type = args
        .get(4)
        .and_then(|arg| {
            if let OscType::String(t) = arg {
                Some(t.clone())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "builtin".to_string());
    let device_file = args
        .get(5)
        .and_then(|arg| {
            if let OscType::String(f) = arg {
                Some(f.clone())
            } else {
                None
            }
        })
        .unwrap_or_default();
    Some(AudioCommand::AddDeviceToChannel {
        channel_id,
        parent_path,
        device_id,
        device_type,
        device_file,
        position,
        active,
        enabled,
    })
}

/// `{device}/modulator/...` commands:
/// - `modulator/add [i:mod_id, s:kind]`
/// - `modulator/clear`
/// - `modulator/{mod_id}/remove`
/// - `modulator/{mod_id}/param/{id}/value [f:norm]`
/// - `modulator/{mod_id}/route/set [s:target, f:amount]`
fn parse_modulator_command(
    channel_id: usize,
    device_path: DevicePath,
    action: &[&str],
    args: &[OscType],
) -> Option<AudioCommand> {
    match action {
        ["modulator", "add"] => match (args.first(), args.get(1)) {
            (Some(OscType::Int(mod_id)), Some(OscType::String(kind))) => u8::try_from(*mod_id)
                .ok()
                .map(|mod_id| AudioCommand::AddModulator {
                    channel_id,
                    device_path,
                    mod_id,
                    kind: kind.clone(),
                }),
            _ => None,
        },
        ["modulator", "clear"] => Some(AudioCommand::ClearModulators {
            channel_id,
            device_path,
        }),
        ["modulator", mod_id, "remove"] => {
            mod_id
                .parse::<u8>()
                .ok()
                .map(|mod_id| AudioCommand::RemoveModulator {
                    channel_id,
                    device_path,
                    mod_id,
                })
        }
        ["modulator", mod_id, "param", param_id, "value"] => {
            match (mod_id.parse::<u8>(), param_id.parse::<u32>(), args.first()) {
                (Ok(mod_id), Ok(param_id), Some(OscType::Float(value))) => {
                    Some(AudioCommand::SetModulatorParameter {
                        channel_id,
                        device_path,
                        mod_id,
                        param_id,
                        value: *value,
                    })
                }
                _ => {
                    warn!(
                        "Ignoring modulator/{mod_id}/param/{param_id}/value: expected one float \
                         (normalized), got {args:?}"
                    );
                    None
                }
            }
        }
        ["modulator", mod_id, "route", "set"] => {
            match (mod_id.parse::<u8>(), args.first(), args.get(1)) {
                (Ok(mod_id), Some(OscType::String(target)), Some(OscType::Float(amount))) => {
                    Some(AudioCommand::SetModulatorRoute {
                        channel_id,
                        device_path,
                        mod_id,
                        target: target.clone(),
                        amount: *amount,
                    })
                }
                _ => None,
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::parse::test_support::string;

    #[test]
    fn modulator_commands_parse() {
        let path = DevicePath::root(0);
        let add = [OscType::Int(2), string("lfo")];
        match parse_modulator_command(2, path, &["modulator", "add"], &add) {
            Some(AudioCommand::AddModulator {
                channel_id: 2,
                mod_id: 2,
                kind,
                ..
            }) => assert_eq!(kind, "lfo"),
            other => panic!("unexpected: {:?}", other.is_some()),
        }
        assert!(matches!(
            parse_modulator_command(2, path, &["modulator", "clear"], &[]),
            Some(AudioCommand::ClearModulators { channel_id: 2, .. })
        ));
        assert!(matches!(
            parse_modulator_command(2, path, &["modulator", "3", "remove"], &[]),
            Some(AudioCommand::RemoveModulator { mod_id: 3, .. })
        ));
        match parse_modulator_command(
            2,
            path,
            &["modulator", "3", "param", "10", "value"],
            &[OscType::Float(0.4)],
        ) {
            Some(AudioCommand::SetModulatorParameter {
                mod_id: 3,
                param_id: 10,
                value,
                ..
            }) => assert_eq!(value, 0.4),
            other => panic!("unexpected: {:?}", other.is_some()),
        }
        match parse_modulator_command(
            2,
            path,
            &["modulator", "3", "route", "set"],
            &[string("param/2"), OscType::Float(-0.5)],
        ) {
            Some(AudioCommand::SetModulatorRoute {
                mod_id: 3,
                target,
                amount,
                ..
            }) => {
                assert_eq!(target, "param/2");
                assert_eq!(amount, -0.5);
            }
            other => panic!("unexpected: {:?}", other.is_some()),
        }
        // Wrong argument types, an out-of-range id and an unknown action are all dropped.
        let bad = [string("lfo"), OscType::Int(2)];
        assert!(parse_modulator_command(2, path, &["modulator", "add"], &bad).is_none());
        let big = [OscType::Int(300), string("lfo")];
        assert!(parse_modulator_command(2, path, &["modulator", "add"], &big).is_none());
        assert!(parse_modulator_command(2, path, &["modulator", "bogus"], &[]).is_none());
        // The old mod/* addresses are gone.
        assert!(parse_modulator_command(2, path, &["mod", "set"], &add).is_none());
    }
}
