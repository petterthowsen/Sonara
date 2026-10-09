//! Device routes: `/channel/{id}/device/{path}/...` and the channel-level device chain edits.

use anyhow::Result;
use rosc::OscType;
use tracing::{info, warn};

use super::{device_slots, RouteCtx};
use crate::audio::devices::DevicePath;
use crate::audio::types::ParamSetValue;
use crate::audio::AudioCommand;
use crate::osc::audio_files::{generate_device_request_id, is_audio_sample_path};
use crate::osc::gui::parse_embed_args;
use crate::osc::parse::{segment, ArgError, Args};

/// Dispatch `/channel/{id}/device/{path}/...` commands (nested `child` segments allowed).
pub(super) fn handle_device_message(
    channel_id: usize,
    device_path: DevicePath,
    action: &[String],
    args: &[OscType],
    cx: &mut RouteCtx,
) -> Result<()> {
    let a = Args::new(cx.addr, args);
    let action_refs: Vec<&str> = action.iter().map(|s| s.as_str()).collect();
    match action_refs.as_slice() {
        ["activate"] => {
            cx.commands.send(AudioCommand::SetDeviceActive {
                channel_id,
                device_path,
                active: a.bool(0)?,
            })?;
        }
        ["enable"] => {
            cx.commands.send(AudioCommand::SetDeviceEnabled {
                channel_id,
                device_path,
                enabled: a.bool(0)?,
            })?;
        }
        ["load_file"] => {
            let file_path = a.string(0)?;
            if is_audio_sample_path(file_path) {
                let req_id = match a.opt_string(1) {
                    Some(id) if !id.is_empty() => id.to_string(),
                    _ => generate_device_request_id(channel_id, &device_path),
                };
                cx.server.begin_device_sample_load(
                    channel_id,
                    device_path,
                    None,
                    file_path.to_string(),
                    req_id,
                    cx.commands,
                )?;
            } else {
                cx.commands.send(AudioCommand::LoadDeviceFile {
                    channel_id,
                    device_path,
                    file_path: file_path.to_string(),
                })?;
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
            let window_handle = cx.windows.create_window(process_key, 800, 600, embed);
            if let (Some(_), Some((parent_xid, _))) = (window_handle, embed) {
                cx.server
                    .send_gui_embedded(channel_id, &device_path, parent_xid);
            }
            cx.commands.send(AudioCommand::OpenPluginGui {
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
                    if cx.windows.embed_window(&process_key, parent_xid, rect) {
                        cx.server
                            .send_gui_embedded(channel_id, &device_path, parent_xid);
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
                Some((_, rect)) => cx.windows.set_embed_bounds(&process_key, rect),
                None => warn!(
                    "gui/bounds: expected x y w h [scroll_x scroll_y], got {:?}",
                    args
                ),
            }
        }
        ["gui", "unembed"] => {
            let process_key = device_path.to_window_key(channel_id);
            if cx.windows.unembed_window(&process_key) {
                cx.server.send_gui_embedded(channel_id, &device_path, 0);
            }
        }
        ["gui", "visible"] => {
            let visible = a.lenient_int(0)? != 0;
            let process_key = device_path.to_window_key(channel_id);
            cx.windows.set_window_visible(&process_key, visible);
            cx.commands.send(AudioCommand::SetPluginGuiVisible {
                channel_id,
                device_path,
                visible,
            })?;
        }
        ["gui", "size"] => {
            let (width, height) = (a.lenient_int(0)?, a.lenient_int(1)?);
            if width > 0 && height > 0 {
                cx.commands.send(AudioCommand::SetPluginGuiSize {
                    channel_id,
                    device_path,
                    width: width as u32,
                    height: height as u32,
                })?;
            } else {
                warn!("gui/size: expected w:i h:i (positive), got {:?}", args);
            }
        }
        ["gui", "close"] => {
            // Hide the host window and take it out of the Godot window first, so Godot can
            // free its window at once. It is destroyed once the plugin confirms the close.
            let process_key = device_path.to_window_key(channel_id);
            if cx.windows.release_window(&process_key) {
                cx.server.send_gui_embedded(channel_id, &device_path, 0);
            }
            cx.commands.send(AudioCommand::ClosePluginGui {
                channel_id,
                device_path,
            })?;
        }
        ["param", param_id_str] => {
            let param_id: u32 = segment(cx.addr, param_id_str)?;
            let value = match args.first() {
                Some(OscType::Float(v)) => ParamSetValue::Normalized(*v),
                Some(OscType::Int(i)) => ParamSetValue::Index(*i),
                _ => return Err(a.mismatch(0, "f or i").into()),
            };
            cx.commands.send(AudioCommand::SetDeviceParameter {
                channel_id,
                device_path,
                param_id,
                value,
            })?;
        }
        ["modulator", ..] => {
            let cmd = parse_modulator_command(channel_id, device_path, &action_refs, &a)?;
            cx.commands.send(cmd)?;
        }
        ["data", "subscribe"] => {
            cx.commands.send(AudioCommand::SubscribeDeviceData {
                channel_id,
                device_path,
                data_type: a.string(0)?.to_string(),
            })?;
        }
        ["data", "unsubscribe"] => {
            cx.commands.send(AudioCommand::UnsubscribeDeviceData {
                channel_id,
                device_path,
                data_type: a.string(0)?.to_string(),
            })?;
        }
        ["data", "configure"] => {
            let (data_type, key) = (a.string(0)?, a.string(1)?);
            // The value may arrive as f, i or d.
            let value = match args.get(2) {
                Some(OscType::Float(v)) => *v,
                Some(OscType::Int(v)) => *v as f32,
                Some(OscType::Double(v)) => *v as f32,
                _ => return Err(a.mismatch(2, "f, i or d").into()),
            };
            cx.commands.send(AudioCommand::ConfigureDeviceData {
                channel_id,
                device_path,
                data_type: data_type.to_string(),
                key: key.to_string(),
                value,
            })?;
        }
        ["add_device"] => {
            let cmd = parse_add_device_command(channel_id, device_path, &a)?;
            cx.commands.send(cmd)?;
        }
        ["remove_device"] => {
            cx.commands.send(AudioCommand::RemoveDeviceFromChannel {
                channel_id,
                parent_path: device_path,
                position: a.int(0)? as usize,
            })?;
        }
        ["move_device"] => {
            cx.commands.send(AudioCommand::MoveDevice {
                channel_id,
                parent_path: device_path,
                from_position: a.int(0)? as usize,
                to_position: a.int(1)? as usize,
            })?;
        }
        ["get_parameters"] => {
            cx.commands.send(AudioCommand::GetPluginParameters {
                channel_id,
                device_path,
            })?;
        }
        ["state", "get"] => {
            cx.commands.send(AudioCommand::GetDeviceState {
                channel_id,
                device_path,
            })?;
        }
        ["state", "save"] => {
            cx.commands.send(AudioCommand::SavePluginState {
                channel_id,
                device_path,
                file_path: a.string(0)?.to_string(),
            })?;
        }
        ["state", "load"] => {
            cx.commands.send(AudioCommand::LoadPluginState {
                channel_id,
                device_path,
                file_path: a.string(0)?.to_string(),
            })?;
        }
        // Reload a crashed plugin: respawn its host and restore its state (Phase 4).
        ["reload"] => {
            cx.commands.send(AudioCommand::ReloadDevice {
                channel_id,
                device_path,
            })?;
        }
        _ => {
            if !device_slots::route(channel_id, device_path, &action_refs, args, cx)? {
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
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        // Device management - path-based: /channel/{id}/add_device
        ["channel", channel_id_str, "add_device"] => {
            let channel_id: usize = segment(cx.addr, channel_id_str)?;
            let cmd = parse_add_device_command(channel_id, DevicePath::default(), &a)?;
            if let AudioCommand::AddDeviceToChannel {
                device_id,
                device_type,
                position,
                active,
                enabled,
                ..
            } = &cmd
            {
                info!(
                    "Add device {} (type={}) to channel {} at position {} [active={}, enabled={}]",
                    device_id, device_type, channel_id, position, active, enabled
                );
            }
            cx.commands.send(cmd)?;
        }
        ["channel", channel_id_str, "remove_device"] => {
            let channel_id: usize = segment(cx.addr, channel_id_str)?;
            let position = a.int(0)?;
            info!(
                "Remove device from channel {} at position {}",
                channel_id, position
            );
            cx.commands.send(AudioCommand::RemoveDeviceFromChannel {
                channel_id,
                parent_path: DevicePath::default(),
                position: position as usize,
            })?;
        }
        ["channel", channel_id_str, "move_device"] => {
            let channel_id: usize = segment(cx.addr, channel_id_str)?;
            let (from_pos, to_pos) = (a.int(0)?, a.int(1)?);
            info!(
                "Move device in channel {} from position {} to position {}",
                channel_id, from_pos, to_pos
            );
            cx.commands.send(AudioCommand::MoveDevice {
                channel_id,
                parent_path: DevicePath::default(),
                from_position: from_pos as usize,
                to_position: to_pos as usize,
            })?;
        }
        ["channel", channel_id_str, "clear_devices"] => {
            let channel_id: usize = segment(cx.addr, channel_id_str)?;
            info!("Clear all devices from channel {}", channel_id);
            cx.commands
                .send(AudioCommand::ClearChannelDevices { channel_id })?;
        }

        _ => return Ok(false),
    }
    Ok(true)
}

/// Parse `/add_device` arguments shared by channel-root and nested container paths:
/// `s:device_id i:position [i:active i:enabled s:type s:file]`. The optional values default
/// (active and enabled true, type `builtin`, no file) when absent or of another type.
fn parse_add_device_command(
    channel_id: usize,
    parent_path: DevicePath,
    a: &Args,
) -> Result<AudioCommand, ArgError> {
    Ok(AudioCommand::AddDeviceToChannel {
        channel_id,
        parent_path,
        device_id: a.string(0)?.to_string(),
        // Device type (builtin, clap, lv2, vst3)
        device_type: a.opt_string(4).unwrap_or("builtin").to_string(),
        // Path to the plugin, empty for built-ins
        device_file: a.opt_string(5).unwrap_or_default().to_string(),
        position: a.int(1)?,
        active: a.opt_bool(2).unwrap_or(true),
        enabled: a.opt_bool(3).unwrap_or(true),
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
    a: &Args,
) -> Result<AudioCommand, ArgError> {
    let addr = a.addr();
    match action {
        ["modulator", "add"] => {
            let mod_id = a.int(0)?;
            let kind = a.string(1)?.to_string();
            let mod_id = u8::try_from(mod_id).map_err(|_| {
                ArgError::invalid(addr, format!("modulator id {mod_id} is out of range"))
            })?;
            Ok(AudioCommand::AddModulator {
                channel_id,
                device_path,
                mod_id,
                kind,
            })
        }
        ["modulator", "clear"] => Ok(AudioCommand::ClearModulators {
            channel_id,
            device_path,
        }),
        ["modulator", mod_id, "remove"] => Ok(AudioCommand::RemoveModulator {
            channel_id,
            device_path,
            mod_id: segment(addr, mod_id)?,
        }),
        ["modulator", mod_id, "param", param_id, "value"] => {
            Ok(AudioCommand::SetModulatorParameter {
                channel_id,
                device_path,
                mod_id: segment(addr, mod_id)?,
                param_id: segment(addr, param_id)?,
                value: a.float(0)?,
            })
        }
        ["modulator", mod_id, "route", "set"] => Ok(AudioCommand::SetModulatorRoute {
            channel_id,
            device_path,
            mod_id: segment(addr, mod_id)?,
            target: a.string(0)?.to_string(),
            amount: a.float(1)?,
        }),
        _ => Err(ArgError::invalid(addr, "unknown modulator action")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::parse::test_support::string;

    /// `parse_modulator_command` on channel 2, device 0.
    fn parse(action: &[&str], args: &[OscType]) -> Result<AudioCommand, ArgError> {
        let a = Args::new("/channel/2/device/0/modulator", args);
        parse_modulator_command(2, DevicePath::root(0), action, &a)
    }

    #[test]
    fn modulator_commands_parse() {
        let add = [OscType::Int(2), string("lfo")];
        match parse(&["modulator", "add"], &add) {
            Ok(AudioCommand::AddModulator {
                channel_id: 2,
                mod_id: 2,
                kind,
                ..
            }) => assert_eq!(kind, "lfo"),
            other => panic!("unexpected: {:?}", other.is_ok()),
        }
        assert!(matches!(
            parse(&["modulator", "clear"], &[]),
            Ok(AudioCommand::ClearModulators { channel_id: 2, .. })
        ));
        assert!(matches!(
            parse(&["modulator", "3", "remove"], &[]),
            Ok(AudioCommand::RemoveModulator { mod_id: 3, .. })
        ));
        match parse(
            &["modulator", "3", "param", "10", "value"],
            &[OscType::Float(0.4)],
        ) {
            Ok(AudioCommand::SetModulatorParameter {
                mod_id: 3,
                param_id: 10,
                value,
                ..
            }) => assert_eq!(value, 0.4),
            other => panic!("unexpected: {:?}", other.is_ok()),
        }
        match parse(
            &["modulator", "3", "route", "set"],
            &[string("param/2"), OscType::Float(-0.5)],
        ) {
            Ok(AudioCommand::SetModulatorRoute {
                mod_id: 3,
                target,
                amount,
                ..
            }) => {
                assert_eq!(target, "param/2");
                assert_eq!(amount, -0.5);
            }
            other => panic!("unexpected: {:?}", other.is_ok()),
        }
        // Wrong argument types, an out-of-range id and an unknown action are all rejected
        // (and now logged by the router).
        let bad = [string("lfo"), OscType::Int(2)];
        assert!(parse(&["modulator", "add"], &bad).is_err());
        let big = [OscType::Int(300), string("lfo")];
        assert!(parse(&["modulator", "add"], &big).is_err());
        assert!(parse(&["modulator", "bogus"], &[]).is_err());
        // The old mod/* addresses are gone.
        assert!(parse(&["mod", "set"], &add).is_err());
        // A value that is an int, not a float, is still rejected.
        assert!(parse(
            &["modulator", "3", "param", "10", "value"],
            &[OscType::Int(1)]
        )
        .is_err());
    }

    #[test]
    fn add_device_defaults_optional_arguments() {
        let parse = |args: &[OscType]| {
            let a = Args::new("/channel/1/add_device", args);
            parse_add_device_command(1, DevicePath::default(), &a)
        };
        // Only the id and the position are required.
        match parse(&[string("polysynth"), OscType::Int(0)]) {
            Ok(AudioCommand::AddDeviceToChannel {
                device_id,
                device_type,
                device_file,
                position,
                active,
                enabled,
                ..
            }) => {
                assert_eq!(device_id, "polysynth");
                assert_eq!(
                    (device_type.as_str(), device_file.as_str()),
                    ("builtin", "")
                );
                assert_eq!(position, 0);
                assert!(active && enabled);
            }
            other => panic!("unexpected: {:?}", other.is_ok()),
        }
        // Wrongly typed optional values take their defaults rather than failing.
        match parse(&[
            string("x"),
            OscType::Int(2),
            OscType::Float(0.0),
            OscType::Int(0),
            OscType::Int(5),
            string("/p.clap"),
        ]) {
            Ok(AudioCommand::AddDeviceToChannel {
                device_type,
                device_file,
                active,
                enabled,
                ..
            }) => {
                assert!(
                    active,
                    "a float flag reads as absent, so it defaults to true"
                );
                assert!(!enabled);
                assert_eq!(device_type, "builtin");
                assert_eq!(device_file, "/p.clap");
            }
            other => panic!("unexpected: {:?}", other.is_ok()),
        }
        // The required arguments are checked.
        assert!(parse(&[]).is_err());
        assert!(parse(&[string("x")]).is_err());
        assert!(parse(&[string("x"), OscType::Float(1.0)]).is_err());
    }
}
