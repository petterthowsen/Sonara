//! Channel routes: `/channel/{id}/*` (the device routes are in `device.rs`).

use anyhow::Result;
use rosc::OscType;
use tracing::info;

use super::RouteCtx;
use crate::audio::AudioCommand;
use std::time::Instant;

/// Handle channel routes: `/channel/{id}/*` (the device routes are in `device.rs`). Returns false for an address this area doesn't
/// know, so the caller can try the next area or report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    match parts {
        // Channel management - path-based: /channel/{id}/{command}
        ["channel", id_str, "create"] => {
            if let (Ok(id), Some(OscType::String(name))) = (id_str.parse::<usize>(), args.first()) {
                info!("Create channel {} ({})", id, name);
                cx.commands.send(AudioCommand::CreateChannel {
                    id,
                    name: name.clone(),
                })?;
            }
        }
        ["channel", id_str, "remove"] => {
            if let Ok(id) = id_str.parse::<usize>() {
                info!("Remove channel {}", id);
                cx.commands.send(AudioCommand::RemoveChannel { id })?;
            }
        }
        ["channel", id_str, "volume"] => {
            if let (Ok(id), Some(OscType::Float(db))) = (id_str.parse::<usize>(), args.first()) {
                cx.commands
                    .send(AudioCommand::SetChannelVolume { id, db: *db })?;
            }
        }
        ["channel", id_str, "pan"] => {
            if let Ok(id) = id_str.parse::<usize>() {
                // Check if we have 1 or 2 pan values
                if let Some(OscType::Float(pan_left)) = args.get(0) {
                    let pan_right = args.get(1).and_then(|arg| {
                        if let OscType::Float(val) = arg {
                            Some(*val)
                        } else {
                            None
                        }
                    });
                    cx.commands.send(AudioCommand::SetChannelPan {
                        id,
                        pan_left: *pan_left,
                        pan_right,
                    })?;
                }
            }
        }
        ["channel", id_str, "pan_mode"] => {
            if let (Ok(id), Some(OscType::Int(mode))) = (id_str.parse::<usize>(), args.first()) {
                cx.commands
                    .send(AudioCommand::SetChannelPanMode { id, mode: *mode })?;
            }
        }
        ["channel", id_str, "pan_width"] => {
            if let (Ok(id), Some(OscType::Float(width))) = (id_str.parse::<usize>(), args.first()) {
                cx.commands
                    .send(AudioCommand::SetChannelPanWidth { id, width: *width })?;
            }
        }
        ["channel", id_str, "mute"] => {
            if let (Ok(id), Some(OscType::Int(mute))) = (id_str.parse::<usize>(), args.first()) {
                cx.commands.send(AudioCommand::SetChannelMute {
                    id,
                    mute: *mute != 0,
                })?;
            }
        }
        ["channel", id_str, "solo"] => {
            if let (Ok(id), Some(OscType::Int(solo))) = (id_str.parse::<usize>(), args.first()) {
                cx.commands.send(AudioCommand::SetChannelSolo {
                    id,
                    solo: *solo != 0,
                })?;
            }
        }
        ["channel", id_str, "route"] => {
            if let (Ok(id), Some(OscType::Int(output_id))) = (id_str.parse::<usize>(), args.first())
            {
                let output = if *output_id < 0 {
                    None
                } else {
                    Some(*output_id as usize)
                };
                cx.commands.send(AudioCommand::SetChannelRoute {
                    id,
                    output_id: output,
                })?;
            }
        }
        ["channel", id_str, "aux_out"] => {
            if let Ok(id) = id_str.parse::<usize>() {
                let bus_index = args.first().and_then(|a| match a {
                    OscType::Int(v) if *v >= 0 => Some(*v as usize),
                    _ => None,
                });
                let target_id = args.get(1).and_then(|a| match a {
                    OscType::Int(v) if *v >= 0 => Some(*v as usize),
                    _ => None,
                });
                if let (Some(bus_index), Some(target_id)) = (bus_index, target_id) {
                    cx.commands.send(AudioCommand::SetAuxOut {
                        id,
                        bus_index,
                        target_id,
                    })?;
                }
            }
        }

        // MIDI routing configuration
        ["channel", id_str, "midi_input_device"] => {
            if let (Ok(id), Some(OscType::Int(device_id))) = (id_str.parse::<usize>(), args.first())
            {
                cx.commands.send(AudioCommand::SetMidiInputDevice {
                    channel_id: id,
                    device_id: *device_id,
                })?;
            }
        }
        ["channel", id_str, "record_armed"] => {
            if let (Ok(id), Some(OscType::Int(armed))) = (id_str.parse::<usize>(), args.first()) {
                cx.commands.send(AudioCommand::SetRecordArmed {
                    channel_id: id,
                    armed: *armed != 0,
                })?;
            }
        }

        // MIDI events - path-based: /channel/{id}/midi_event
        ["channel", id_str, "midi_event"] => {
            if let Ok(channel_id) = id_str.parse::<usize>() {
                // Args: channel_id, message, midi_channel, pitch, velocity, timestamp_us
                // Godot's timestamp is on a different clock, so the engine stamps arrival instead
                let received_at = Instant::now();
                if let (
                    Some(OscType::Int(_)), // channel_id (redundant, already in path)
                    Some(OscType::Int(message)),
                    Some(OscType::Int(midi_channel)),
                    Some(OscType::Int(pitch)),
                    Some(OscType::Int(velocity)),
                ) = (
                    args.get(0),
                    args.get(1),
                    args.get(2),
                    args.get(3),
                    args.get(4),
                ) {
                    cx.commands.send(AudioCommand::MidiEvent {
                        channel_id,
                        message_type: *message as u8,
                        midi_channel: *midi_channel as u8,
                        note: *pitch as u8,
                        velocity: *velocity as u8,
                        received_at,
                    })?;
                }
            }
        }
        ["channel", id_str, "midi_cc"] => {
            if let Ok(channel_id) = id_str.parse::<usize>() {
                // Args: channel_id, midi_channel, cc_number, cc_value, timestamp_us
                // Godot's timestamp is on a different clock, so the engine stamps arrival instead
                let received_at = Instant::now();
                if let (
                    Some(OscType::Int(_)), // channel_id (redundant)
                    Some(OscType::Int(midi_channel)),
                    Some(OscType::Int(cc_number)),
                    Some(OscType::Int(cc_value)),
                ) = (args.get(0), args.get(1), args.get(2), args.get(3))
                {
                    cx.commands.send(AudioCommand::MidiEvent {
                        channel_id,
                        message_type: 11, // MIDI_MESSAGE_CONTROL_CHANGE
                        midi_channel: *midi_channel as u8,
                        note: *cc_number as u8,
                        velocity: *cc_value as u8,
                        received_at,
                    })?;
                }
            }
        }

        // Send management - path-based: /channel/{id}/send/{target_id}/{command}
        ["channel", id_str, "send", target_str, "add"] => {
            if let (Ok(channel_id), Ok(target_channel_id)) =
                (id_str.parse::<usize>(), target_str.parse::<usize>())
            {
                // Args: amount_db (float), pre_fader (int 0/1)
                let amount_db = args
                    .get(0)
                    .and_then(|v| match v {
                        OscType::Float(f) => Some(*f),
                        OscType::Int(i) => Some(*i as f32),
                        _ => None,
                    })
                    .unwrap_or(-12.0); // Default -12 dB

                let pre_fader = args
                    .get(1)
                    .and_then(|v| match v {
                        OscType::Int(i) => Some(*i != 0),
                        _ => None,
                    })
                    .unwrap_or(false); // Default post-fader

                cx.commands.send(AudioCommand::AddSend {
                    channel_id,
                    target_channel_id,
                    amount_db,
                    pre_fader,
                })?;
            }
        }
        ["channel", id_str, "send", target_str, "remove"] => {
            if let (Ok(channel_id), Ok(target_channel_id)) =
                (id_str.parse::<usize>(), target_str.parse::<usize>())
            {
                cx.commands.send(AudioCommand::RemoveSend {
                    channel_id,
                    target_channel_id,
                })?;
            }
        }
        ["channel", id_str, "send", target_str, "amount"] => {
            if let (Ok(channel_id), Ok(target_channel_id)) =
                (id_str.parse::<usize>(), target_str.parse::<usize>())
            {
                if let Some(amount_db) = args.get(0).and_then(|v| match v {
                    OscType::Float(f) => Some(*f),
                    OscType::Int(i) => Some(*i as f32),
                    _ => None,
                }) {
                    cx.commands.send(AudioCommand::SetSendAmount {
                        channel_id,
                        target_channel_id,
                        amount_db,
                    })?;
                }
            }
        }
        ["channel", id_str, "send", target_str, "pre_fader"] => {
            if let (Ok(channel_id), Ok(target_channel_id)) =
                (id_str.parse::<usize>(), target_str.parse::<usize>())
            {
                if let Some(OscType::Int(pre_fader)) = args.first() {
                    cx.commands.send(AudioCommand::SetSendPreFader {
                        channel_id,
                        target_channel_id,
                        pre_fader: *pre_fader != 0,
                    })?;
                }
            }
        }
        ["channel", id_str, "send", target_str, "mute"] => {
            if let (Ok(channel_id), Ok(target_channel_id)) =
                (id_str.parse::<usize>(), target_str.parse::<usize>())
            {
                if let Some(OscType::Int(muted)) = args.first() {
                    cx.commands.send(AudioCommand::SetSendMute {
                        channel_id,
                        target_channel_id,
                        muted: *muted != 0,
                    })?;
                }
            }
        }
        _ => return Ok(false),
    }
    Ok(true)
}
